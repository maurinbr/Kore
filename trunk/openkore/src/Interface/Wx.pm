#########################################################################
#  OpenKore - WxWidgets Interface
#  You need:
#  * WxPerl (the Perl bindings for WxWidgets) - http://wxperl.sourceforge.net/
#
#  More information about WxWidgets here: http://www.wxwidgets.org/
#
#  Copyright (c) 2004 OpenKore development team 
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
#  $Revision$
#  $Id$
#
#########################################################################
package Interface::Wx;

use strict;
use Wx ':everything';
use Wx::Event qw(EVT_CLOSE EVT_MENU EVT_MENU_OPEN EVT_LISTBOX_DCLICK EVT_CHOICE);
use Time::HiRes qw(time sleep);
use File::Spec;


use Globals;
use Interface;
use base qw(Wx::App Interface);
use Modules;
use Interface::Wx::Dock;
use Interface::Wx::MapViewer;
use Interface::Wx::Console;
use Interface::Wx::Input;
use Interface::Wx::ItemList;
use AI;
use Settings;
use Plugins;
use Misc;
use Commands;
use Utils;


our $iterationTime;
our $controlTime;
our $itemListTime;


sub OnInit {
	my $self = shift;

	$self->createInterface;
	$self->iterate;

	$self->{loadHook} = Plugins::addHook('loadfiles', sub { $self->onLoadFiles(@_); });
	$self->{postLoadHook} = Plugins::addHook('postloadfiles', sub { $self->onLoadFiles(@_); });

	$self->{history} = [];
	$self->{historyIndex} = -1;

	Modules::register("Interface::Wx::Dock");
	Modules::register("Interface::Wx::MapViewer");
	Modules::register("Interface::Wx::Console");
	Modules::register("Interface::Wx::Input");
	Modules::register("Interface::Wx::ItemList");
	return 1;
}

sub DESTROY {
	my $self = shift;
	Plugins::delHook($self->{loadHook});
	Plugins::delHook($self->{postLoadHook});
}

our $itemListTime;

sub iterate {
	my $self = shift;

	if (timeOut($controlTime, 0.15)) {
		$self->updateStatusBar;
		$self->updateMapViewer;
		$controlTime = time;
	}
	if (timeOut($itemListTime, 0.35)) {
		$self->{itemList}->set(\@playersID, \%players, \@monstersID, \%monsters, \@itemsID, \%items);
		$itemListTime = time;
	}

	while ($self->Pending) {
		$self->Dispatch;
	}
	$self->Yield;
	$iterationTime = time;
}

sub getInput {
	my $self = shift;
	my $timeout = shift;
	my $msg;

	if ($timeout < 0) {
		while (!defined $self->{input} && !$quit) {
			$self->iterate;
			sleep 0.01;
		}
		$msg = $self->{input};

	} elsif ($timeout == 0) {
		$msg = $self->{input};

	} else {
		my $begin = time;
		until (defined $self->{input} || time - $begin > $timeout || $quit) {
			$self->iterate;
			sleep 0.01;
		}
		$msg = $self->{input};
	}

	undef $self->{input};
	undef $msg if (defined($msg) && $msg eq "");

	# Make sure we update the GUI. This is to work around the effect
	# of functions that block for a while
	$self->iterate if (timeOut($iterationTime, 0.05));

	return $msg;
}

sub writeOutput {
	my $self = shift;
	$self->{console}->add(@_);
	# Make sure we update the GUI. This is to work around the effect
	# of functions that block for a while
	$self->iterate if (timeOut($iterationTime, 0.05));
}

sub title {
	my $self = shift;
	my $title = shift;

	if (defined $title) {
		if ($title ne $self->{title}) {
			$self->{frame}->SetTitle($title);
			$self->{title} = $title;
		}
	} else {
		return $self->{title};
	}
}

sub displayUsage {
	my $self = shift;
	my $text = shift;
	print $text;
}

sub errorDialog {
	my $self = shift;
	my $msg = shift;
	my $fatal = shift;

	my $title = ($fatal) ? "Fatal error" : "Error";
	Wx::MessageBox($msg, "$title - $Settings::NAME", wxICON_ERROR, $self->{frame});
}


################################


sub createInterface {
	my $self = shift;

	### Main window
	my $frame = $self->{frame} = new Wx::Frame(undef, -1, $Settings::NAME);
	$self->{title} = $frame->GetTitle();


	### Menu bar
	my $menu = $self->{menu} = new Wx::MenuBar();
	$frame->SetMenuBar($menu);

		# Program menu
		my $opMenu = new Wx::Menu;
		$self->{mPause}  = $self->addMenu($opMenu, '&Pause Botting', \&onDisableAI, 'Pause all automated botting activity');
		$self->{mResume} = $self->addMenu($opMenu, '&Resume Botting', \&onEnableAI, 'Resume all automated botting activity');
		$opMenu->AppendSeparator;
		$self->addMenu($opMenu, 'E&xit	Ctrl-W', \&main::quit, 'Exit this program');
		$menu->Append($opMenu, 'P&rogram');
		EVT_MENU_OPEN($opMenu, sub { $self->onMenuOpen; });

		my $infoMenu = new Wx::Menu;
		$self->addMenu($infoMenu, '&Status	Alt-S',	sub { Commands::run("s"); });
		$self->addMenu($infoMenu, 'S&tatistics',	sub { Commands::run("st"); });
		$self->addMenu($infoMenu, '&Inventory	Alt-I',	sub { Commands::run("i"); });
		$self->addMenu($infoMenu, 'S&kills',		sub { Commands::run("skills"); });
		$infoMenu->AppendSeparator;
		$self->addMenu($infoMenu, '&Players	Alt-P',	sub { Commands::run("pl"); });
		$self->addMenu($infoMenu, '&Monsters	Alt-M',	sub { Commands::run("ml"); });
		$self->addMenu($infoMenu, '&NPCs',		sub { Commands::run("nl"); });
		$infoMenu->AppendSeparator;
		$self->addMenu($infoMenu, '&Experience Report	Alt+E',	sub { main::parseInput("exp"); });
		$menu->Append($infoMenu, 'I&nfo');

		# View menu
		my $viewMenu = new Wx::Menu;
		$self->addMenu($viewMenu, '&Map	Ctrl-M',	\&onMapToggle, 'Show where you are on the current map');
		$viewMenu->AppendSeparator;
		$self->addMenu($viewMenu, '&Font...',		\&onFontChange, 'Change console font');
		$viewMenu->AppendSeparator;
		$self->addMenu($viewMenu, '&Clear Console',	\&onClearConsole);
		$menu->Append($viewMenu, '&View');

		$self->createCustomMenus() if $self->can('createCustomMenus');

		# Help menu
		my $helpMenu = new Wx::Menu();
		$self->addMenu($helpMenu, '&Manual	F1',		\&onManual, 'Read the manual');
		$self->addMenu($helpMenu, '&Forum	Shift-F1',	\&onForum, 'Visit the forum');
		$menu->Append($helpMenu, '&Help');


	### Vertical box sizer
	my $vsizer = new Wx::BoxSizer(wxVERTICAL);
	$frame->SetSizer($vsizer);


	## Splitter with console and another splitter
	my $splitter = new Wx::SplitterWindow($frame, 928, wxDefaultPosition, wxDefaultSize,
		wxSP_LIVE_UPDATE);
	$splitter->SetMinimumPaneSize(25);
	$vsizer->Add($splitter, 1, wxGROW);

		my $console = $self->{console} = new Interface::Wx::Console($splitter);
		my $subSplitter = new Wx::SplitterWindow($splitter, 583,
			wxDefaultPosition, wxDefaultSize, wxSP_LIVE_UPDATE);

			## Inside this splitter is a player/monster/item list, and a dock with map viewer

			my $itemList = $self->{itemList} = new Interface::Wx::ItemList($subSplitter);
			$itemList->onActivate(\&onItemListActivate, $self);
			$subSplitter->Initialize($itemList);


			my $mapDock = $self->{mapDock} = new Interface::Wx::Dock($subSplitter, -1, 'Map');
			$mapDock->Show(0);
			$mapDock->setHideFunc($self, sub {
				$subSplitter->Unsplit($mapDock);
				$mapDock->Show(0);
				$self->{inputBox}->SetFocus;
			});
			$mapDock->setShowFunc($self, sub {
				$subSplitter->SplitVertically($itemList, $mapDock, -$mapDock->GetBestSize->GetWidth);
				$mapDock->Show(1);
				$self->{inputBox}->SetFocus;
			});

			my $mapView = $self->{mapViewer} = new Interface::Wx::MapViewer($mapDock);
			$mapDock->setParentFrame($frame);
			$mapDock->set($mapView);
			$mapView->onMouseMove(sub {
				# Mouse moved over the map viewer control
				my (undef, $x, $y) = @_;
				my $walkable;

				if ($Settings::CVS =~ /CVS/) {
					$walkable = checkFieldWalkable(\%field, $x, $y);
				} else {
					$walkable = !ord(substr($field{rawMap}, $y * $field{width} + $x, 1));
				}

				if ($x >= 0 && $y >= 0 && $walkable) {
					$self->{mouseMapText} = "Mouse over: $x, $y";
				} else {
					delete $self->{mouseMapText};
				}
				$self->{statusbar}->SetStatusText($self->{mouseMapText}, 0);
			});
			$mapView->onClick(sub {
				# Clicked on map viewer control
				my (undef, $x, $y) = @_;
				delete $self->{mouseMapText};
				$self->writeOutput("message", "Moving to $x, $y\n", "info");
				#AI::clear("mapRoute", "route", "move");
				main::aiRemove("mapRoute");
				main::aiRemove("route");
				main::aiRemove("move");
				main::ai_route($field{name}, $x, $y);
				$self->{inputBox}->SetFocus;
			});
			$mapView->onMapChange(sub {
				$mapDock->title($field{name});
				$mapDock->Fit;
			});
			if (%field && $char) {
				$mapView->set($field{name}, $char->{pos_to}{x}, $char->{pos_to}{y}, \%field);
			}

		$splitter->SplitVertically($console, $subSplitter, -150);


	### Input field
	my $hsizer = new Wx::BoxSizer(wxHORIZONTAL);
	$vsizer->Add($hsizer, 0, wxGROW);

	my $inputBox = $self->{inputBox} = new Interface::Wx::Input($frame);
	$inputBox->onEnter($self, \&onInputEnter);
	$hsizer->Add($inputBox, 1, wxGROW);

	my $choice = $self->{inputType} = new Wx::Choice($frame, 456, wxDefaultPosition, wxDefaultSize,
			['Command', 'Public chat', 'Private chat', 'Party chat', 'Guild chat']);
	$choice->SetSelection(0);
	EVT_CHOICE($self, 456, sub { $inputBox->SetFocus; });
	$hsizer->Add($choice, 0, wxGROW);


	### Status bar
	my $statusbar = $self->{statusbar} = new Wx::StatusBar($frame, -1, wxST_SIZEGRIP);
	$statusbar->SetFieldsCount(3);
	$statusbar->SetStatusWidths(-1, 65, 175);
	$frame->SetStatusBar($statusbar);


	#################

	$frame->SetSizeHints(300, 250);
	$frame->SetClientSize(730, 400);
	$frame->SetIcon(Wx::GetWxPerlIcon);
	$frame->Show(1);
	$self->SetTopWindow($frame);
	$inputBox->SetFocus;
	EVT_CLOSE($frame, \&onClose);

	# Hide console on Win32
	if ($buildType == 0 && !($Settings::CVS =~ /CVS/)) {
		eval 'use Win32::Console; Win32::Console->new(STD_OUTPUT_HANDLE)->Free();';
	}
}

sub addMenu {
	my ($self, $menu, $label, $callback, $help) = @_;

	$self->{menuIDs}++;
	my $item = new Wx::MenuItem(undef, $self->{menuIDs}, $label, $help);
	$menu->Append($item);
	EVT_MENU($self->{frame}, $self->{menuIDs}, sub { $callback->($self); });
	return $item;
}

sub updateStatusBar {
	my $self = shift;

	my ($statText, $xyText, $aiText) = ('', '', '');

	if ($self->{loadingFiles}) {
		$statText = sprintf("Loading files... %.0f%%", $self->{loadingFiles}{percent} * 100);
	} elsif (!$conState) {
		$statText = "Initializing...";
	} elsif ($conState == 1) {
		$statText = "Not connected";
	} elsif ($conState > 1 && $conState < 5) {
		$statText = "Connecting...";
	} elsif ($self->{mouseMapText}) {
		$statText = $self->{mouseMapText};
	}

	if ($conState == 5) {
		$xyText = "$char->{pos_to}{x}, $char->{pos_to}{y}";

		if ($AI) {
			if (@ai_seq) {
				my @seqs = @ai_seq;
				foreach (@seqs) {
					s/^route_//;
					s/_/ /g;
					s/([a-z])([A-Z])/$1 $2/g;
					$_ = lc $_;
				}
				substr($seqs[0], 0, 1) = uc substr($seqs[0], 0, 1);
				$aiText = join(', ', @seqs);
			} else {
				$aiText = "";
			}
		} else {
			$aiText = "Paused";
		}
	}

	# Only set status bar text if it has changed
	my $i = 0;
	my $setStatus = sub {
		if (defined $_[1] && $self->{$_[0]} ne $_[1]) {
			$self->{$_[0]} = $_[1];
			$self->{statusbar}->SetStatusText($_[1], $i);
		}
		$i++;
	};

	$setStatus->('statText', $statText);
	$setStatus->('xyText', $xyText);
	$setStatus->('aiText', $aiText);
}

sub updateMapViewer {
	my $self = shift;
	my $map = $self->{mapViewer};
	return unless ($map && %field && $char);

	my $myPos = calcPosition($char);
	$map->set($field{name}, $myPos->{x}, $myPos->{y}, \%field);
	my $i = binFind(\@ai_seq, "route");
	if (defined $i) {
		$map->setDest($ai_seq_args[$i]{dest}{pos}{x}, $ai_seq_args[$i]{dest}{pos}{y});
	} else {
		$map->setDest;
	}

	my @players = values %players;
	$map->setPlayers(\@players);
	my @monsters = values %monsters;
	$map->setMonsters(\@monsters);

	$map->update;
	$self->{mapViewTimeout}{time} = time;
}


################## Callbacks ##################

sub onInputEnter {
	my $self = shift;
	my $text = shift;
	my $command;

	my $n = $self->{inputType}->GetSelection;
	if ($n == 0 || $text =~ /^\/(.*)/) {
		my $command = ($n == 0) ? $text : $1;
		$self->{console}->SetDefaultStyle($self->{console}{inputStyle});
		$self->{console}->AppendText("$command\n");
		$self->{console}->SetDefaultStyle($self->{console}{defaultStyle});
		$self->{inputBox}->Remove(0, -1);
		$self->{input} = $command;
		return;
	}

	return unless $conState == 5;
	if ($n == 1) { # Public chat
		main::sendMessage(\$remote_socket, "c", $text);
	} elsif ($n == 2) { # Private chat
		$self->{console}->add("error", "This feature is not supported yet. Please use the 'pm' command.\n");
	} elsif ($n == 3) { # Party chat
		main::sendMessage(\$remote_socket, "p", $text);
	} else { # Guild chat
		main::sendMessage(\$remote_socket, "g", $text);
	}
}

sub onLoadFiles {
	my ($self, $hook, $param) = @_;
	if ($hook eq 'loadfiles') {
		$self->{loadingFiles}{percent} = $param->{current} / scalar(@{$param->{files}});
	} else {
		delete $self->{loadingFiles};
	}
}

sub onMenuOpen {
	my $self = shift;
	$self->{mPause}->Enable($AI);
	$self->{mResume}->Enable(!$AI);
}

sub onEnableAI {
	$AI = 1;
}

sub onDisableAI {
	$AI = 0;
}

sub onClose {
	my $self = shift;
	$self->Show(0);
	main::quit();
}

sub onFontChange {
	my $self = shift;
	$self->{console}->selectFont($self->{frame});
}

sub onClearConsole {
	my $self = shift;
	$self->{console}->Remove(0, -1);
}

sub onMapToggle {
	my $self = shift;
	$self->{mapDock}->attach;
}

sub onManual {
	my $self = shift;
	launchURL('http://openkore.sourceforge.net/manual/');
}

sub onForum {
	my $self = shift;
	launchURL('http://openkore.sourceforge.net/forum.php');
}

sub onItemListActivate {
	my $self = shift;
	my $ID = shift;
	my $object = shift;
	my $type = shift;

	if ($type eq 'p') {
		if ($Settings::CVS =~ /CVS/) {
			Commands::run("pl " . $players{$ID}{binID}) if ($players{$ID});
		}

	} elsif ($type eq 'm') {
		main::attack($ID) if ($monsters{$ID});

	} elsif ($type eq 'i') {
		if ($items{$ID}) {
			$self->{console}->add("message", "Taking item $items{$ID}{name} ($items{$ID}{binID})\n", "info");
			main::take($ID);
		}
	}

	$self->{inputBox}->SetFocus;
}

1;
