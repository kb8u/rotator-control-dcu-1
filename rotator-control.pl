#!/usr/bin/env perl
# Aim a DCU-1 protocol compatible rotor using a GUI and map
# Written December 30, 2014 and copyright by Russell Dwarshuis, KB8U
# See the LICENSE files for terms of use.

use strict;
use feature qw(unicode_strings say);
use English;
use File::Slurp;
use Try::Tiny;
use Tk;
use Tk::JPEG;
use Tk::Dialog;
use Tk::Help;
use Device::SerialPort qw( :STAT 0.07 );
use File::HomeDir;
use Getopt::Std;
$Getopt::Std::STANDARD_HELP_VERSION = 1; # so --help goes to stdout
our $VERSION = '1.0.0';

use lib '/home/kb8u/bin/rotator-control-dcu-1/lib';
use Heading 'heading_to';


my $TAU = 6.28318530718; # 2 x pi
my $default_image;
while(<DATA>) {
  chomp;
  $default_image .= pack('H*', $_);
}

my $sp;
my $port;
my $from_grid;
my @map;
# files, labels and tk photo objects for background image
my $current_pix;
my ($pix_label1,$pix_label2,$pix_label3);
my ($file1,$file2,$file3);
my ($pix1,$pix2,$pix3);

getopts('d:h');
our ($opt_d,$opt_h);

# directory for configuration file
my $CONFIG_DIR = $opt_d 
               ? $opt_d : File::HomeDir->my_data().'/rotator-control-dcu-1';

my $map_menu;
($pix_label1, $file1,
 $pix_label2, $file2,
 $pix_label3, $file3,
 $port,$from_grid) =
   read_file("$CONFIG_DIR/config",err_mode => 'quiet', chomp => 1);
# default values if file can't be read
unless (defined $pix_label1) {
  $port = '/dev/ttyS1';
  $pix_label1 = 'Default';
}

# compass rose outer radius in pixels
my $RADIUS = 231;

my $HELP = <<"EOH";
command line options:
  -d directory to hold configuration data.  Defaults to
     $CONFIG_DIR
     If this directory does not exist, it will be created.

  -h Print help message

Generate maps to show in the main window by using Great Circle Maps by SM3GSJ
L<http://www.qsl.net/sm3gsj/>
Download additional border .pnt files from:
L<http://www.spatial.ucsb.edu/map-projections/anderson/SSMap_Data.zip>
Set the size of map option to 500 pixels.
Save files to disk and set the location of them in the setup menu.

Set the serial port (e.g. /dev/ttyUSB0 or /dev/ttyS1) in the setup menu.

On linux, you will need to permit users to access the serial port by running
the following command from a terminal:
sudo usermod -a -G dialout \$USER
EOH


# can't use variables like $HELP in getopt's HELP_MESSAGE.  Why??
sub HELP_MESSAGE {
  print "use -h for help\n";
  exit;
}


if ($opt_h) {
  print $HELP;
  exit;
}

my $mw = new MainWindow;
$mw->title("Rotor control");

my $canvas = $mw->Canvas( -height =>504, -width => 504);
$canvas->pack(-side => 'bottom', -anchor => 'center', -expand => 1,
              -fill => 'both');

# send an opcode and get raw data back from rotor
# returns 1 on success, 0 otherwise
sub query_rotor {
  my ($command, $result_ref, $size) = @_;

  return 0 unless $sp;
  $sp->write($command);

  my ($count_in, $string_in) = $sp->read($size);
  $$result_ref = $string_in;
  return 1 if $count_in == $size;

  $$result_ref = '';
  return 0
}


# update GUI
sub repeat_handler {
  my ($canv,$line_ref,
      $direction_entry_ref,$text_direction_ref)= @_;

  my $result;
  my ($x,$y,$radians);
  return unless query_rotor("AI1;",\$result,4);

  my ($heading) = split /;/,$result;
  unless ($heading =~ /^\d{3}$/) { return }
  # don't overwrite with current heading if direction entry has focus
  unless (defined $mw->focusCurrent 
          && $mw->focusCurrent == $$direction_entry_ref) {
    $$text_direction_ref = int($heading) . "\N{DEGREE SIGN}";
  }
  $heading -= 90; # adjust from rotors to Tk's idea of what angle represents
  $radians = $TAU*($heading/360); # cos, sin needs radians, not degrees
  $x = int ($RADIUS * cos $radians);
  $y = int ($RADIUS * sin $radians);
  $canv->delete($$line_ref);
  $$line_ref = $canv->createLine(0,0,$x,$y,-fill => 'green', -width => 3);
}


# draw a line through the coordinates passed to the compas rose
sub heading_line {
  my ($args) = @_;
  my $line_ref = $args->{line_ref};
  my $cx = $args->{cx};
  my $cy = $args->{cy};
  my $color = $args->{color};

  my $angle = atan2($cy,$cx);
  my $rx = $RADIUS * cos $angle;
  my $ry = $RADIUS * sin $angle;
  $canvas->delete($$line_ref);
  $$line_ref = $canvas->createLine(0,0,$rx,$ry,-fill => $color, -width => 3);
}


# move to a new heading based on text typed in 
sub new_heading_from_text {
  my ($widget, $line_ref, $text_ref) = @_;

  my $to_grid;
  my $call_prefix;
  # grid square?
  if (   $$text_ref =~ /^([A-Za-z][A-Za-z]\d\d[A-Za-z][A-Za-z])$/
      || $$text_ref =~ /^([A-Za-z][A-Za-z]\d\d)$/) {
    $to_grid = $1 }
  else {
    $call_prefix = $$text_ref;
  }
  my $deg = heading_to($from_grid,$to_grid,$call_prefix);
  return if (! defined $deg);
  # place a red line at the new heading
  my $radians = $TAU*(($deg-90)/360); # cos, sin needs radians, not degrees
  my $x = int ($RADIUS * cos $radians);
  my $y = int ($RADIUS * sin $radians);
  my $args = { line_ref => $line_ref,
               canvas => $canvas,
               cx => $x,
               cy => $y,
               color => 'red' };
  heading_line($args);
  $deg = sprintf("%03d",int $deg);
  $sp->write("AP1$deg;") if $sp;
  $mw->after(200);
  $sp->write('AM1;') if $sp;
}


# called when button 1 is double clicked; aims the rotator at cursor position
# and draws a red line to compass rose
sub aim_it {
  my ($canv, $x, $y, $line_ref) = @_;
  my $cx = $canv->canvasx($x);
  my $cy = $canv->canvasy($y); # y-axis is upside down from conventional system
  my $deg = atan2($cy,$cx)*360/$TAU;
  # compass has 0 degrees at north, not east. 2nd quadrant needs +90+360,
  # others +90
  $deg = ($deg <-90) ? int ($deg+450) : int($deg + 90); 

  # place a red line at the selected heading
  my $args = { line_ref => $line_ref,
               canvas => $canv,
               cx => $cx,
               cy => $cy,
               color => 'red' };
  heading_line($args);
  $deg = sprintf("%03d",int $deg);
  $sp->write("AP1$deg;") if $sp;
  $mw->after(200);
  $sp->write('AM1;') if $sp;
}


# bound to mouse movement; draws a black line through mouse position to
# compass rose
sub prelim_aim {
  my ($canv, $x, $y, $line_ref) = @_;
  my $cx = $canv->canvasx($x);
  my $cy = $canv->canvasy($y); # y-axis is upside down from conventional system
  my $deg = atan2($cy,$cx)*360/$TAU;
  # compass has 0 degrees at north, not east. 2nd quadrant needs +90+360,
  # others +90
  $deg = ($deg <-90) ? int ($deg+450) : int($deg + 90); 

  # place a black line at the selected heading
  my $args = { line_ref => $line_ref,
               canvas => $canv,
               cx => $cx,
               cy => $cy,
               color => 'black' };
  heading_line($args);
}


sub save_and_hide {
  my ($setup_canvas) = @_;
  set_serial_port(\$sp);
  set_map_menu();
  if (defined $from_grid) {
    $from_grid =~ s/\s+//g;
    # convert 4 digit to 6 digit (assume near center of square)
    if ($from_grid =~ /^[a-z][a-z][0-9][0-9]$/i) { $from_grid .= 'mm' }
    if ($from_grid !~ /^[a-z][a-z][0-9][0-9][a-z][a-z]$/i) {
      $from_grid = undef;
      $mw->Dialog(-title => 'Invalid grid square',
                  -bitmap => 'warning',
                  -text => 'Grid square should be like FN20 or FN20xq',
                  -default_button => 'Close',
                  -buttons => ['Close'])->Show();
    }
  }
  my @file_contents = (
       ($pix_label1 // ''),($file1 // ''),
       ($pix_label2 // ''),($file2 // ''),
       ($pix_label3 // ''),($file3 // ''),
       $port,
       ($from_grid // ''));
  @file_contents = map { $_ = "$_\n" } @file_contents;

  mkdir $CONFIG_DIR unless -d $CONFIG_DIR;
  unless (write_file("$CONFIG_DIR/config",
                     {err_mode => 'quiet'},
                     @file_contents)) {
    $mw->Dialog(-title => "Can't save configuration",
                -bitmap => 'warning',
                -text => "Could not save configuration to $CONFIG_DIR/config",
                -default_button => 'Close',
                -buttons => ['Close'])->Show();
  }
  $$setup_canvas->withdraw;
}


sub select_file {
  my ($setup_cannvas,$file_ref) = @_;
  my $new_file =
    $$setup_cannvas->getOpenFile(-filetypes=>[['Images',['.gif','.jpg']]]);
  $$file_ref = $new_file // $$file_ref;
}


sub setup {
  my ($setup_canvas) = @_;


  if (! Exists($$setup_canvas)) {
    $$setup_canvas = $mw->Toplevel
      (
       -title => 'rotator-control setup',
       -takefocus => 1,
      );
    $$setup_canvas->Label(-text => 'Map label')->grid
      ($$setup_canvas->Label(-text => 'Map file path'));
    $$setup_canvas->Entry(-textvariable => \$pix_label1)->grid
      ($$setup_canvas->Entry(-textvariable => \$file1,
                             -width => 40),
       $$setup_canvas->Button(-text => 'File...',
                              -command => [ \&select_file, $setup_canvas, \$file1 ]));

    $$setup_canvas->Entry(-textvariable => \$pix_label2)->grid
      ($$setup_canvas->Entry(-textvariable => \$file2,
                             -width => 40),
       $$setup_canvas->Button(-text => 'File...',
                              -command => [ \&select_file, $setup_canvas, \$file2 ]));

    $$setup_canvas->Entry(-textvariable => \$pix_label3)->grid
      ($$setup_canvas->Entry(-textvariable => \$file3,
                             -width => 40),
       $$setup_canvas->Button(-text => 'File...',
                              -command => [ \&select_file, $setup_canvas, \$file3 ]));

    $$setup_canvas->Label(-text => 'Serial Port')->grid
      ($$setup_canvas->Entry(-textvariable => \$port,
                             -width => 40));
    $$setup_canvas->Label(-text => 'Grid Square')->grid
      ($$setup_canvas->Entry(-textvariable => \$from_grid,
                             -width => 40));
    $$setup_canvas->Button
      (
       -text => 'Close',
       -command => [ \&save_and_hide, $setup_canvas ],
      )->grid(-row => 6, -column => 1);
  }
  else {
    $$setup_canvas->deiconify();
    $$setup_canvas->raise();
  }
}


sub exit_gracefully {
  undef $sp;
  $mw->destroy();
  exit;
}


sub create_pix {
  my ($file, $pix_ref, $default_image_ref) = @_;

  unless ($file) {
    $$pix_ref = $canvas->Photo(-data => $$default_image_ref);
    return;
  }

  try {
    $$pix_ref = $canvas->Photo(-file => $file);
  }
  catch {
    $$pix_ref = $canvas->Photo(-data => $$default_image_ref);
    $mw->Dialog(-title => 'Invalid image file',
                -bitmap => 'warning',
                -text => "Can't process $file, using default instead",
                -default_button => 'Close',
                -buttons => ['Close'])->Show();
  }
}


# set the map options when first run or after setup change
sub set_map_menu {
  # clear old menu items
  $map_menu->menu->delete(0, 'end');

  create_pix($file1, \$pix1, \$default_image);
  create_pix($file2, \$pix2, \$default_image);
  create_pix($file3, \$pix3, \$default_image);

  $map[0]=['command', -label => ($pix_label1 // 'Map 1'),
           -command => [\&set_map, $pix1, \$current_pix]];
  if ($pix_label2) {
    $map[1]=['command', -label => ($pix_label2 // ''),
             -command => [\&set_map, $pix2, \$current_pix]];
  }
  if ($pix_label3) {
      $map[2]=['command', -label => ($pix_label3 // ''),
               -command => [\&set_map, $pix3, \$current_pix]];
  }
  foreach my $item (@map) {
    $map_menu->menu->add(@{$item}) if defined $item;
  }
}


# change the map
sub set_map {
  my ($new_pix, $current_pix) = @_;

  # get rid of the old picture first
  $canvas->delete($$current_pix);
  $$current_pix = $canvas->createImage(0, 0,
                                       -image => $new_pix,
                                       -anchor => 'center');
  $canvas->lower($$current_pix,'all');
  $canvas->configure(-scrollregion => [$canvas->bbox("all") ]);
  # initialize the view to more-or-less the middle of the drawing
  $canvas->xview('moveto',0.11);
  $canvas->yview('moveto',0.24);
}


# configure serial port
sub set_serial_port {
  my ($sp_ref) = @_;
 
  # close any old serial port first
  eval { $$sp_ref->close();
         undef $$sp_ref;
  };
  $$sp_ref = new Device::SerialPort($port);
  $$sp_ref || warn "Can't open serial port $port: $^E\n"
              . "Did you run `sudo usermod -a -G dialout \$USER` ?\n";
  if ($$sp_ref) {
    $$sp_ref->databits(8);
    $$sp_ref->baudrate(4800);
    $$sp_ref->parity("none");
    $$sp_ref->stopbits(1);
    $$sp_ref->handshake("none");

    $$sp_ref->write_settings || die "Couldn't configure serial port $port\n";

    $$sp_ref->read_const_time(50);
  }
}


sub tkhelp {
  my @helparray = ([{-title => 'rotator-control',
                     -header => 'rotator-control help',
                     -text => "Computer control a DCU-1 protocol compatible rotor control"}],
                   [{-title => 'Application basic usage',
                     -header => "Application basic usage",
                     -text => 
'You may need to set the serial port in the Setup menu first (see next section).  If everything is working you should see numbers in the Heading text box and a green line on the map will show where the rotator is pointing.

Double click anywhere on the map to move the rotator to the desired direction.  A red line will appear showing where the rotator is moving to.  The rotator may over or undershoot a little, this is normal.

You can also enter a callsign prefix or grid square into the Heading textbox.  Enter return to move the rotor to that location.  Set your grid square in the Setup menu first.'
                   }],
                   [{-title => 'Serial port',
                     -header => 'Serial port',
                     -text => 
'Set the serial port (e.g. /dev/ttyUSB0 or /dev/ttyS1) in the setup menu.

On linux, you will need to permit users to access the serial port by running the following command from a terminal: sudo usermod -a -G dialout $USER'
                   }],
                   [{-title => 'Command line options',
                     -header => 'Command line options',
                     -text =>
'-d directory to hold configuration data.  If none is specified, a default will be created.

-h Print help message'
                   }],
                   [{-title => 'Maps',
                     -header => 'Maps',
                     -text =>
'Generate maps to show in the main window by using Great Circle Maps by SM3GSJ http://www.qsl.net/sm3gsj/

Download additional border .pnt files from http://www.spatial.ucsb.edu/map-projections/anderson/SSMap_Data.zip

Set the size of map option to 500 pixels. Save files to disk and set the location of them in the setup menu.  Select from up to three maps from the Map menu.'
                   }]);
  $mw->Help(-title => 'rotator-control help',
            -variable => \@helparray);
}


########################## main #########################
# Create Photo objects
create_pix($file1, \$pix1, \$default_image);
create_pix($file2, \$pix2, \$default_image);
create_pix($file3, \$pix3, \$default_image);

# draw a map to start with
set_map($pix1,\$current_pix);

# set the scroll region to the proper size
$canvas->configure(-scrollregion => [$canvas->bbox("all") ]);

# initialize the view to more-or-less the middle of the drawing
$canvas->xview('moveto',0.11);
$canvas->yview('moveto',0.24);

# have to bind to stuff in the canvas, not the canvas itself
my ($desired_dir,$prelim_dir);
$canvas->Tk::bind("<Double-Button-1>",
                     [ \&aim_it, Ev('x'), Ev('y'), \$desired_dir ]);
$canvas->Tk::bind("<Motion>",
                    [ \&prelim_aim,  Ev('x'), Ev('y'), \$prelim_dir ]);
$canvas->Tk::bind("<Leave>", [ sub { $canvas->delete($prelim_dir) }]);

# create frame for menus along the very top
my $top_menu_frame = $mw->Frame
  (

   -borderwidth => 2,
   -height => 18,
  );
$top_menu_frame->pack(-side=>'top', -fill => 'x');
$top_menu_frame->packPropagate(0);
# place file and map menus in top_menu_frame
my $file_menu = $top_menu_frame->Menubutton
  (
   -text => 'File',
   -tearoff => 0,
   -menuitems => [[ 'command' => "Exit", -command => \&exit_gracefully],]
  );
$file_menu->pack(-side =>'left');
$map_menu = $top_menu_frame->Menubutton
  (
   -text => 'Map',
   -tearoff => 0,
   -menuitems => \@map,
  );
$map_menu->pack(-side =>'left');
set_map_menu();

my $setup_canvas = 0;
my $setup_button = $top_menu_frame->Button
  (
   -text => 'Setup',
   -relief => 'flat',
   -command => [\&setup, \$setup_canvas]
  );
$setup_button->pack(-side => 'left');
my $help_button = $top_menu_frame->Button
  (
   -text => 'Help',
   -relief => 'flat',
   -command => sub { tkhelp() }
  );
$help_button->pack(-side => 'left');

# a frame for the current beam heading, moving indicator and stop button
my $info_frame = $mw->Frame
  (
   -borderwidth => 2,
   -height => 30,
   -width => 500,
  );
$info_frame->pack(-side=>'top', -fill => 'x');
$info_frame->packPropagate(0);
# a text entry field for current direction
my $text_direction;
my $direction_entry = $info_frame->Entry
  (
   -textvariable => \$text_direction,
   -width => 7,
   -font => "Arial 12 bold",
   -foreground => 'green',
   -background => 'black',
   -insertbackground => 'white',
  );
# numeric indicator/input of beam heading
$direction_entry->pack(-side =>'left');
$direction_entry->bind("<Return>", [\&new_heading_from_text,
                                    \$desired_dir, \$text_direction]);
my $dir_descr_text = $info_frame->Label(-text=>'Heading')->pack(-side =>'left');

# button/indicator to stop beam movment/indicates movement
my $stop_Button = $info_frame->Button
  (
   -text => 'STOP',
   -command => [ sub { $sp->write(";") if $sp } ],
  );
$stop_Button->pack(-side => 'left');
$dir_descr_text = $info_frame->Label(-text=>'Movement')->pack(-side =>'left');

set_serial_port(\$sp);
unless ($sp) {
  $mw->Dialog(-title => 'Problem with serial port',
              -bitmap => 'warning',
              -text => "Could not open serial port $port.  Choose a different serial port in the Setup menu and/or make sure you run `sudo usermod -a -G dialout \$USER` from the command line",
              -default_button => 'Close',
              -buttons => ['Close'])->Show();
}

my $beam_pointer;
$mw->repeat(100,[\&repeat_handler,$canvas,\$beam_pointer,
                                  \$direction_entry,\$text_direction,]);
$mw->focusFollowsMouse();
MainLoop;
exit(0);
# End of main

=head1 rotator-control-dcu-1 help

=head2 usage

You may need to set the serial port in the Setup menu first (see below).  If
everything is working you should see numbers in the Heading text box
and a green line on the map will show where the rotator is pointing.

Double click anywhere on the map to move the rotator to the desired direction.
A red line will appear showing where the rotator is moving to.  The rotator may
over or undershoot a little, this is normal.

=head2 command line options

-d directory to hold configuration data.  If none is specified, a default
will be created.

-h Print help message

=head2 maps

Generate maps to show in the main window by using Great Circle Maps by SM3GSJ
http://www.qsl.net/sm3gsj/
Download additional border .pnt files from:
http://www.spatial.ucsb.edu/map-projections/anderson/SSMap_Data.zip
Set the size of map option to 500 pixels
Save files to disk and set the location of them in the setup menu.
Select from up to three maps from the Map menu.

=head2 serial port

Set the serial port (e.g. /dev/ttyUSB0 or /dev/ttyS1) in the setup menu.

On linux, you will need to permit users to access the serial port by running
the following command from a terminal:
sudo usermod -a -G dialout $USER
=cut


# default image
__DATA__
474946383961f401f401e7fc0004000600020008000002020f04011710000102
05010005080d001600061718020502061f050803000a03000912200200140414
010827180800090c08090e00340200010e35070c441c0e2d250f181317142311
2307192e12191c2f12123413041817321f1919151b28231b031f1a21251a1340
190750190f2726293b230e3b221c2423592d2249501b3736280f3f213d3a252c
232a49312c2718324d302d40253432263442333337363427253d19573e487439
2750443d41466e33498452427150465649486167433d6247267344196b452953
494e5d4a354d4d4b4d4f422d54764a4f534150653853624f5135494f5b58502c
3b517851561156479a5c4f463d575373561726666a4f6c935c6d7f6a69857369
6c8c67598f6847836b547e6a707d6c649e673a7470656e7175856f4a7872585d
797a6f70a4647b5c9577568f776d857a7c7481717a7ba47d7e7e6781a4738294
7584825e88a5648991877f937c858d8a84799394948b95a4b58f71ab9185a791
98a19d89b09a8fc09a68ba9a7e94a48ea49f95a8a17ea7a0a1a79fb5a29ecea9
a48a9fa5a495a5c9b19fbc9da6ba91aab8a2a6af81abe386accd95abb097aca9
cbb4a6fbaf7dddbab0d5bea2d1beb0cebdc5dab8dad5bebbc6c4b3e4b9c8c9c1
dac4c5c2c7c5bcc5c4ccb3cacbb2c8eed4bdf8bfc5f1cccb92bec8dac0c9cda1
d0f2cecba7b2cedfeec2a8a8d3d1ecc97cf0c999d7d6d4e4d3d5f7cfc6d8d6dc
efd3b8dad7cfd3d9ded9dac7ead8c9cbe3e5f4dcbfdbe5c4e9e0cfdee3d2e8e0
d9efdedfefdfeae5e0fff5dcfee6e6e4dbeaede3e9fde9e9f1c3f4ffe5ecf1d7
effdfee7dbfce7e3dfedfef1e8fcffeabfcef8ecffedd1fff0b9fff1cae2f6ef
f6f5ecfff2f3fffaa5fbf9bde8f8ffd1fffff4f6f3fff4e7faf5f3fdf3fff5f6
fff1f8fcfcfac9f9f6fbfff9d6fff8e3fff7f0e0fffdfff6fce4fff7f2fde3fe
fcd2eefef1fffbdef1feebf8fbf7fff9f8e9fffef3fdf8edfff8f6fcfefdfaff
fcfcf2fafcf9faffdcfffcedf1fffffdfee7f5fffafffcfbf8fff3fbffeefffe
f5fffdfff9fffffcfffbfefffc2c00000000f401f4010008fe00ff091c48b0a0
c18308132a5cc8b0a1c38710234a9c2810debb7af7e8c583c7afdebb7ff1d6c1
1be92e9ec981ef52d2cbe7111e3688fafe5dbca70f9bc596ebe25d84c8efa0ba
7ffc7a7e14c86f9d3e7d29e1c5a377f3e3388a50a34a9d4ab5aad5ab58b36add
ca3522bc7f1e4daee33754e63f78eb085eacf76f5d369929e3c57ca8f3a346b4
f1ce7e8d59b6614f8423fb0205292f25d1a07fbb2a5eccb8b1e3c790234b1e18
8f6cdc7d7ac1d6abb72edc488b29df5d0b396e1cbf7ca8211aa687d4a33da617
f56de40938a84075eabefef3c631df3da03d45fefb3db9b8f1e3c8932b5f7eb0
72e893ebd2d663c736dcbbe823c7858bc78e1dbc6ce136fee77dc8761deb7b29
77491000805458da0739921da83b253f93b6e3edeb399eb9ffff000628e0806d
59f60f66046dc61677f184a30d3ce31ca38f38e27c270d75693dc4ce3ad2ac53
4f3efa8c13c421e854428331efa0035f411ff163117ddeac731137211996d747
fd11a8e38e3cf6e823441ce158238e70bdb30f3afa78939279943410c73b0fb6
a45a5bb17db34b10c9d8838e11a2d43357545ffdf5934c2e7284d23b45c908d2
8f6cb6e9e69bfe7df58e491bd908d447fb7443cf45dd0592c23254b4f10e3cd2
8005d138fbe493923ee6e4124435ff6cb9c93bc44de50d50f2fca38e7da5add3
ce3d1e959956a570966aeaa9a85225d49a7fede3dc75fef108020002364053cf
12957c03ce0cc2c0a3113b409ab46837b73c9acf375cbe93cf541f7194d63581
0870c021b022185a7486a6aaedb6dc762b507f6382d487000324f38e2b155c51
0f5eedd0304c3ee924318879d90a94a942f58423523df674534b0fd5a0630e10
5dce33d0bd0a15751b8b5fa515cf2b2194c24e3afa6052400103d441dd46ba79
ebf1c720eb989799cae6f2800ad2e031433dc89c404c3dda6443cf3f4190c28e
3b7ca841cf6fd9647acd40e12eac2967d2c0e3253ad204f1083a94d0504d3df3
fcfc4fa663564d90c2410fa5b049b518910c39e5e8938126ebb4f284315e4aa3
4dc86cb7edb67179214669349160b30e2c4c0823cdfe0ea87030402ba066c108
4d7dac718f3be7642834d08caf0b4f38a8f133ce2e140820807b734ecdf8e263
06156eb868b565d2294c78a34f37b4f4208c963424b38d6c4fbd2dfbecb46735
14b6201d53c20dc25cc745029ee442c11ce29442053af1104287b2b3fd3426c2
070fb4cd38f1d843263de058b62c3fce6b4e10f405a615b47cd16d07081cdb80
434d255188330f2b58be030e386cd56efffdf837646348fcd9534b2f0450c43f
c0c10e7a98231333b0863a86500007444018fc98d9a534652f0a52f05ef2c887
8bfe01bbaf70ac27f7f8cae72aa8b93145274363fa8837b6160f362ca21ecd70
861ede608df705411cf2b307b0f2c7c31ee6cf46fed8a209382a430a1a5c031d
e200c7333011057684e31bfab0060ec3e1998fe046200118530006b2c57f3400
00606c40000480b10318803d070800030210000374b18bff80e3168382b04d11
a57cd1c2012a0af88c40c8a1805e508438aa410f7ad4cf87884ce4dbca14177b
0cb11ea06842346ea10101280002938ac74bba739d02a8a31e6c0ca51a45c9c6
3506e01d5b4c890136e22200a4e51d0658561cd5c14637969294966363a62620
9391f0271eb290c00098c0af5c2860109e708031d8f10ed9084691d08c26aa42
e24b4ae983120a10400222808a78e86a1c2319c070527280030ce06206a0401c
b9c84e2c562400cb8207003e229201d8c5006cfe91c716332547768e4500ffb0
25000e00c6a234480022794777c0d18c0fd8c01ade61cda0a449d18a6ea56302
99473c3633a87068242ee6a0c4002e80004690831c2104cd3fb2b10e79482968
e0b3e01b49d94f2cdeaba6eb74a74ea756535ab633a740c5a91b87ca46811860
711209978bb4c6910fd1433ad56bcb5852e211908464aa87b4a85643f6198118
465f564d0a364c500a6b408c42eb7aa53ca27391eb842b53e01ba528d7a9c52b
76519f9adb226eba788d2efaf41f7d25483f7fa2d7a04a2d8bfc1cc851090bb4
2dd2148e02915af436173d7870c3aa70f98746ce621afb34682df454cb33b74a
da53c5142e34d9ec3f4af108768ca365c0b0fe0635c440c36a540f1b86919161
bc47415ada920180b5e94efd5a5379046d84a2b4a52ddb184a0398728b921da1
bdf609d40968f1a7711425d534f5d63145d7ab7302876c7e130e17b05111e004
0b3fb0a10f966cc34506224a69e7fb3175886f2c2009070998208e7834630783
b0c63432e10388d2e31bb0399067053bd7a91d35b2c065ec5e85d657513ef7b9
a1b45a6fffc18098f213c316bea501baa7299cc2f11a0cd062832d18d9cda9a3
1d685a4a34c4638e6fc0e2028dd8063a98498fd77864850642107d879caa70bd
4646d401471e74100353b8a31b7e00023ba6910b1f10831dfaf886739c39a878
84728d0399c0cf122bdce392920152eb1efed57e2259ee0677b2cfb3da1507f2
b32b520dc517f6091c1fac0ebc62b1c1726eb1a2c0a911cb7ce31bf0888223ee
410d662e251c60090d9a1243e44aa34a1d837880020e2087241221155a78033b
d0f18c1214a21b77685f3d0a19188d0020010010c088771a582cfe04af347d70
8b4918b40b1a97b2c6bd224c0b821b796cd720b8f16e88b7c867388a79a7eaf8
6d1649f8ade7c4431b0fe2602064500c315020006ee8ea38d1e4cbe158fadc6f
ba063058f00a739ce20ad6d805119a418a0b5ca018faa085040a70836a385a26
b1b6dc3c41425d3f079594d023719bdf6cc15b7f8fc4df73336fc1776c161364
d8d95d2303802b8f5a1bbcb0d90d2506fe418391428e43192070001bccf18787
36a3047bacc7496e071721a3fbe604aa63beba41864f88630c0a28c0012c208a
afd8631e8189a31bcb59a679aa0333d316ec72276b7183ac19a9d48e3865a9dd
ebacd7d15e5f3f6e649b0bd9e172519fa1e40f7ae8d10c13282019e2b847db37
618d6780c111105dca58ee23138f280ee780cf793dc05184072040098b48425e
c6b0849178e31e0300001b117a8fca0320bd0620953ca6ce437e8692da83c562
0304fe11709041000c80033c2c21836dd4035078678726f77e23bf07fef6cb11
bb3ae6810e6c603b0628ea092e7011007012000003f10600d49117008c248340
d1ee697da85dc10a1bb8ed68d0abaffe2300e40121067860433ef6118b102c53
e6f1b0635b6a8efbf62387cd0499873dd6310e2dd0e01ddbf84839e6c1805971
bfadcef71629616c67847c59a748c17658457571b3f41106c00fda707c02706d
16c10750801463e00641113ae8416e66422aee17828e1176ea400f60202d36b0
0d5f1100e5e44a029012d92000a0b22e0580160120460ce04bbfa629d3573b5d
b7614a57547e360eb0c43101200f058000046000f3000502b0000b500c1e651d
92366922788593a161d8921201874ff0a00de3c000f11447eef00f0080310000
2ff1642642f383b36335d73042db7553a67416c8970f261100e8010f05206b01
3000dac063f6a013f52037788285fe88d8180e5711bbf10e680712f77000de30
0ee611008518506d7416dad0136b282615c74376761bce037f05f16b6c0400fc
2100f9d00ed95783d331000a5088ecb551e4165f839188b8981563f21523d116
e514005e9614a8f80fdb010f09c000073012d97012f2201f225410d7d0833ec8
621a5635cf431460240099527908751302200d014788b9255ab9588e57911b02
01466034005e3288f6448901700ef17031d30125da6014e9900eff501aa68159
55d743db456210c780f25026e17454f0604ff7600f053033ff2000fc000003e0
00072024d1411659658e96865f2031160a720fbe418c0e6211ea600ff6900964
040082247385846c24b4800ef6fe539fa7910b618a6e741b77e557d9e5929315
1a16e430ec90119e510fd53027f6900e89f320a345931e831857b34161f50ef6
907fde540b0ec008f1d00a20200aef803d0df766d7604b99d2613ae579773567
4c598a17b77930095d8c157215742f52e3937d212c406111957716f711131092
966e8326af342777c10fde202cec300fe2f10d4df334f1b00731e07a74c68060
365d5fa9463ef3957e692fdd13872d464bd3162e900593dea37e8b9313815000
6bc05147c759eb100da1613d99c936534524f6d119d1b10ff5a8442a800ae2f0
0fcb60028f0051eb308a21c75837556260d63d03e9976247906c39627e465884
b58008e39304b11d81c00b03fe9000a4c0418a022184080fd7009bb1e931b271
9741e21168024ee1300908309170c00fe8400655d09bd46005712045e0e04e30
196d6ff679d5788de5a97025a46141089ad3a5460fd9625644100d1212f56006
4b9050ef2033f9c04cbd519e1f3333f61124f76012e0040f7da000b0f00f9fd0
04b2c70a23c008fff00d643007faf967b6c64e0bc866dde566689996dee513e1
526771846647185cc0b5936a3610396112bb200ef5c008460021e0341dedb03d
b6a1a1de621986b197f4100ee3f020a5c006bc07088b200e584609122001dbb4
4c01a00f4515003f33a43c15755cf76bc236a016576c5363a0b7f1888475583b
0947eaf0160f0a06147000fe0ba00ceb303f244043ab660f30865154aa2d42f2
1ce0500929b90617f10d6560000ee0008fe00ee8f00d42b092fc6000ba56766e
347d8b286c70f5a830752f03099a8ba5582a4642eb200676d0209d80a2f2930a
0a0000041001e6b2268fea2d1f719ef611080df009efc009542013d2d00bcbc4
085550125424000d405039456645d567c30a190ba8938e354600f50f9d20009d
100fbcc001c4900fcf90028cf00ee1000670a0a4d8000e20d8ada6922342510a
7100928010084001869b310648d00e34286bed101402c0ad3f31995487af5b11
670ecb53b7867a08f50f9c20704d500fe8c0054fa0a44ac60452140ee0508610
3b4d96b10fcea482f150fe060dd00003a008944009b5d00109900cf55050eb20
00f0c01bff605dd995663ecaad27bb156916b440b5a00f0950d2710fba0203a0
d05f6db70810d5214b59b43f329b34318810120eb9500eecb0084ad00d0ce406
d3717c32c11b059016dc239a5be786580b151a369651f7575323005bb40eec90
0fe6f00a18200cf9600f7be034e4a0412f12b7a6621920190f459313f6a00f63
c004af110e129900682200aef90e13b80e927799db75b4708bb8517199ce3301
6f444143ba460910b8d9b0017b800ebac00188e025fa9074a2eb2678f82a78f2
0ea5c009b9200100200c4a6980853181ace165ce17ba477bbb53917093a54f1d
765d1f7186ff700ef7fe8009651a008b5094db618bccfb23ae52241c34884630
00cb130009694f01a0113f8150d2e2880b33673b18bfdf4b1523246745857cdc
f01107100eb2f69010422983521f575bbf017213ead913f6f04d44580f2f0b14
f1d000fa802d078000d9f61bcebb75062c15cb791004f511ef509193fb6a61a1
0f5a0a0fed401db1b3c15a81182eecc257433db2d197237313bfb18812377639
c558db2a8d2c7c1c3349a36fa596a13b104e798b9246193f7c18304c107ba113
efc5c44291557dd666b48466c355763ebcc4902159705a58fd99101d6cc48921
14d6c9c5524c6915d10eede53995f122e3714856e379eba4adfba40e43bbc568
bc1841c3466fb94efe13ab960c7710537a26bbb5c74d7c2632c216ea60194e39
730de73c7ecc5342537675bac7c5616cc8753077955dbd867106f117475c1085
8cc9a2b52761b10ef997392031338efa676e1a4774bc61a06bcaef1759d116a4
5f7c9301aa1087181498611bc1acc6a62c69f9400f8d2c6906d55ef45710dfca
620b188d83bcbcb61c19ab7a5c37c9457da64f40cb5b451cca654cccc57c11fd
e2209b317f7bc1978a837640eb53fc348aa4a87bd52c19c90696dc95457f9c61
ff98104402cc9531a5058cc6e7e0483a800138cb31caa21779e1996529a30bf1
cdf3cc15ba5771fd2947bab6cfdf621671731ff4005f3762ca133414f0400df1
c00297203c8cc0fe118f2b250e7954c7b993181dd13ef2cc4665c99c83125333
5164ec55062cce15e14b1c310d963005e3300fceb00185500fe5600f37417023
06727425a0320d27414a99937c8015317338e222e13b1f3d9dc83dcb0fd98018
eb300dbbb002c29065af0002c4d09be3b00dec7046d7e5d09f38d554bd58c025
356bb4aa0ce82bd69312cb32282a7b16017db2898c186fe116d1910fe0a00670
e01de0f00730fa0e4fc10ea3476799620063e670106dd70242b47a059a90b570
74521849cc225f6d75eb970d5b2001c09044cb20038ef00ecdc00af9590d17d3
00394b62751bd39efd23d2ac93231696574d10e8a05f0130a804f00420b14133
e3d31b9c13e1fe500281d00912400c2d4a0b220007c8f00112530f022001dfa9
d930edaa0cf8db6d726b9ed7b05ce4a7b7710b1ed00bd57b088ff90f86cb41fb
81c974c20381d0206030bbf1800ef3e00631a00d3f314f07f0a119726216b770
e8dd233eba3020079d29263493eadaa5e000387bc8b6ec2a26910bd8a0117d80
08dd310fd46048a05400d661d9fa50287e155378fae03a32c408aa53c47d9d5a
12020be01eeac9417a9923b7ab0f568a0eddf00d3cb000a220a6fa000e61f042
9bb1cac857763d2ce321831bd94ca303316acbe001113007e6b00c1960011180
03e5d0773d9d0d36420f29d007ad6003dd219f61400ab620028f80e0efa00e15
5e62824ce5fe2063b7fd1400ec4078a9e9b423400894cd0790a0a49056bf1e14
4f5bd007e0400f71500dd5000fe040048c9000c5b00de5b45b7a055c779ec77c
de2d441b47d108ae99273afa400f5430066c810d5f40b5f5700c063c1e698e0d
3c70000e9000c3700c266003c5f00e0ec0e9df53dc973ceadc52cf994841b3f6
8273620e951003c0f20db50002c610778bfebdc8b35472f15478090876b00eda
f00e60141acb37351d96298651cbc8be2dd648b1eea40ee8b04df4d00d81206a
4a44028dc00e3e66c083085fcce319eb900fe0fe859c3e4f7da18d0b5316d4dc
eea70271f782c503410fba4eb2add004ef800d1f30af03140fbd59bf370c5e39
5148add0fe01a5f05e1549ee1f710d96b33877ce809dedf0040271125b5800b0
1408af6f05b009f5d00e59fa0f3bf4bd77aed520510beb310cc25e9170e15879
4a59312ff3107eec8985be72510f04d07df6a050cd5427f78ab84b3210557542
323100e224587a0cf56c533508f949ec70002aee21cce41916214b06fc7ca811
42e0e48729117502306668cf435e2c0d0a25c1d940f606a00f21748ff160b2df
5b8866d25e9a380e789b5902b1b07f9f3fc7f51305101b139c90699a147659bf
6882591d5a00de90f2dabc6b975f3b548330f2c41fea30002b48d8536373b74b
4f37921296631907b026eebdfaa0f833d3cb3d71641f96b313407ebbd760880f
e97c3efe39f91704fcf6538d8449ee137823fc70fc4452bffab00f10f2223c3b
4f9b710f173b97852dfddde2f79ad38cdca3fb37327010696edc4f4d11e94ad1
71009bc1002c85d3207cfee85f6400f14fdd3f82ffdead8bf7afde3b01f1de1d
a8b72e9b8000f70a5ec49851e3468e1d3d7e041952a4c87704f99de457f05d49
93f5d8e50ba70ddeb972f464b273176f1dbc8105030420d813a8c091458d1e45
9a54e952a64d9d3e85aa54dec00003850e2dc992a5c67cfcc6f1ab67719dc192
090d46459bb6234b942909ae2ce8b55ebd7fe3d645d3090fec3b7808ff5d2308
746860813dd51e469c58f162c68da55e64e053a081b3ffb87123aad1e156b8f1
eebdfee3a777ab63d223d9a254b995dfd8cf7c45df8b171a9e3c7d031900055c
f51fd09e864bff061e5cf8f0c453895e53a74ef7600007e01294b711de3bba3b
e1eacbb7101e3ce2dd2f9e3e99da24bf77f1c0819b0bfa5f3c79dbb9fb0c10bd
a781e802eb7bc79f5ffffedfbe7d039547be9fea4b8ea392f6d969bad14ada8e
bfe0c073abb27f4eaa271c74bec9871d76ea51679fd0e2d1e71fee0c186802a1
8ccbcc41155764b14591ac2208b002875287b2dd7cdb48ac93fada67a594f2b9
871f6d5c2cad2d95c6fb879e70780880020010994b9d75d6a1274404e20b8a30
df0023b24b2fbfc4af272ea1fb8b469f18c011a3847c9c52a17a56f3ac2e3017
33fef2ad8bd671a61239c439279707e8d8709f70c6daed2732792b68cc391765
b451b4602ca8c0f9c614a0d22c35229441ee16faa7cd091d55ab4e8da8a9240a
71eaf9e6991010d9301e78b639201fc2762b483e3241c535575d5f8cf4a2a1d0
244880b5e241279ef4d62468a75da312b5a76c3a9d871e200a79c99c5880a8a6
1a7e0018e01d5985ba745971c7257723e3008cf4b65e89aa079b6f8e30461c77
f459e7ab70261caddca3509330d975acf9e7180feaa8479f5a90d0aeb9037c2d
4c5f871fd6f5be7f842da852610d332c1c0f8ca8e15411b76b933a888de277ab
9ed630e51d70d0e141003a4838a41e780000ab9e03a8ca2ccd9177e6793fe306
fe42ee1fcaae892cd87f6c3d9a15085815040a97de51129e71eea5ab67904ace
329b750219000e76ca99079b4494a9c70006c8e354680225b6ba6db781f32f52
1b8f0e762889fe71c61325d831c70b384eb5871ebe10aafaed8df8bde8d97064
78e58926d841079c71b41987010320ea149ef87a33bc73cf19831430b8062b54
806777e1211b70fe1963907b3784279c7d164ac9a2cf31427ccc78c2314f9d2c
6c6807184fc6190700970cd81d8014ffbabd79e79b12f348cc74a398e26ca818
841d7bf250e39d56d16ea71dd0ee7d7ec2f02e1ae8de84f4b16710021620c600
01c6d9a63a010a8cb17cfdf70f09d2a09e7bc7dc3a55a975c822048f308404fe
30118405084002c1d0d03dce019a71e80f71ea38841bd6b3bb7aa0a31bc76081
28c4410103486d4a0050478890c636feb5d085eb5ac956ec363101f02e1e6548
822e3a50076d68831355b0063bfe910f9d54b079a041488f40430f284021094c
58484906728843ec263a3422dd0bb5b84573f586445a1a8a3d9a51024488231e
cf98441482f80d70f06343ce2b09a10cc28f4094011dd1c8423db65192fa1860
30e05a1e170529c8310da63e3fa14620da508f7898031c2010054ef4918d7178
af7ce79b101532018e4e00200109a883610c25ca5b0dd2942ff4cf40e893ae00
4c630c8da8873958d18142c0631fe960073cb4b10e71382f21880b07efc4fe00
8c7708e309325a0e51cc744a66ba10699211c8501ed08a1590220d1228c53bbc
118fec78651d426cde9a3a9310bdc42321b308c2350c5518c1608485cd84a7e7
eea30e2ec9a39d0289460d917008d06ce739e4c957e7c4091a738a6835fad0c7
121411a0751e0d4bcc8b67449da78ea9704e95867180008a35177e246421ec59
891c3f37d08efeb22f7c10003f69a51c81142d33ef94684c7726a386112539c0
0a00230b40166f00f42d65f1a54168b71e83f4851ef65008a208022c77cad4a9
6df3dfa5aeb14a9002601d682b8b3c56220fb3dc8e35b4b32559e0110f7afc63
00cbcbe253d5fa3902d12a3500f0671cd7240f917a8e3bf7f84c838a0afea77f
1cc05057a4db5a052bcf14154d1d023840b7a61443a27eaa79dc01928f0ae21e
b7d26a9983c5acdbf0979c00ec2300a17948a7d6419df284231b85fb5c39c599
bf99298f3dd12c656665bb338a2e4f00311ccb01ac7a8db984031beb40ade730
c95882b436005dadca3367bb5c7d718e79b7a59d000050914fed231ed70868e7
c2e319b868cdaca0299a6e8e0653e696376210151103da510fb8aea32283fb47
5e9f271b6e7e861fd9904000f6d817b72acabcff5d168eae111d61bd6320ebf0
6b41433adfedd477701471807a96e95f005738573dc9c7769427ab01008001e5
e8ca5764e5307ae49572efb8473e461b2570d8634aab1129a202a017fede90d7
c237c615cedc2a0f01caa3acdb754878f66192ba76491fa189103fe811e4b152
e724de95a37aa5b8ad8bd818c7579ed3b92eb54c8b34e81edaf18b8fbafa257a
10ef1dee70878840148f6c64231c2ed10b8c0393450078839e36b53296f5eca5
3f168a6e5dbe2b983d4a50464d0e1ef7101f8a2d423cee68b524ab598db07e52
12a0b8256e7bc6f49792535bddf8b1b273740b9bc4c90ff281e920e3b82b5eb5
83eaf2982386f0e8a900f851cf7f30c0385c8a6aa675cda2792e5339f591ec90
d944964e2daa9fe481cd4ea4c10305f4021ef54847142704009af1c32a0f4d54
b876bd6dfe58859e54898e3c003381c160724299ca6e97f27ae673fec4631cc8
f840a50a50005b58233d7ca1b6acd7a14ef4f55b67dc06f870b6b4d24201852e
5efe587c27249a45e9832fef484786c791871460771d7d088023ee4d33bdc8fa
b2810c78c8f5d31b96ca3848fe4cf674aaf395e01a1964651d2b199cb6217ad4
2203a5e0c63ba8ad17bdb857e43f9f539f0360806c28c89c3b998b682d39a784
5c556afcd0072e28b0080dfd031b428899cd761ee986fd1be85f0f938c03a0bc
64dd97a8a0252e9832b50d7e60831ef4e044036ab0104b2820182b394068ac2a
acb682ddef0e9aea4a11003517eff11dfa5012751652e42e01662ef138861032
d00a7d9421000e580022f04e647edcaf61abf97be8bb03ae9eb0fe57c1f0c806
3dc4108003d8608f2d27523e5692426c6460000308800038f1b4e938873bf7cd
e294de237ae2030730fc064c3bf8518067df831e93288003ac710f213ca01800
9b93c3cbf30d3dd0a01abdecc300a8fe8f70e83c0067036c7dae81b8e2b7bf31
80acb5000630977cbca2029668c21cee710c2e2c01fb60129cf2e80632780271
10877b000759100152e00b1b590749bb08c0e0076f183ef7b340c41093924322
06e0903e508378f8841a288575e08552e8a5390987e988876e70860e68042132
0773a00242880076f82cb7108070ab15a7bbc01e6c0c837b077b301d04600419
683130201876483717d19e6f00ae77b00403c88172c0064db0fe8020aa00d249
2b1fe442c440911a51874a2a9b00f8866e30812fd8861558047d889c78d010da
f18b9f5a42e148077bc0860d880065683133608002780045b08604c0063f53aa
2e34c4c428a4d65a0809e8067020010230027a48827c5b84f478169d9043fe30
077ae08028a0032af8067da83a6c78b601902303089a4354c547419f811000a4
ab0732d4879c48850aa00162a88748580063a09d6cc044b298c3e048a4184806
69180228380026788776c807e97a36ba112faf5bc5692c0ae57a4595630801f8
865b20814dd890f368024558bc62cbc4fda0062478837778850f10047660814d
58c63e040076a08a5ca3c67b3c8a79020c7b38005b0a8001fe80870770863450
236bb0876e48850460c08310a9b4cb8f6fe80439a8875eb0826e68071f28847a
10c2e96800c2c8337c04498ea0a8cd8a07dd6a08be50806710041b200671a087
3f50804a4c9bef780efd08077d781a74a0864cb80063788702b007b0b80743e1
120a0bc9a3dc089ac29f58f39194a00074708102180002180060b83782789623
e10f6da89285a0074a100044a8860110007b58897840979ef848a40cc9a84288
78e8967130960330007308031848867a58af189246fd18077528077b08074b38
8043909a6e3114b4b40fb664cca300917c802b78a894777000f3b08e440bc6fd
d006889b077078b68860be8fa2882a6bccd20c09b90492fe9d93864a4a0076d8
076cb817877491afa0097a998ee60829f6b819a55c4bd344ca71f08673c88700
b886bed80903a000159b8ec36111bb40b47328ba677380e3da090060894bf3cd
ec2c08e2f98776b807cae82906284b85d8860ad48808d10fbdf0cee28207e718
cef9b14e88b247ed344d9d401be7f02bf22b00c5bb1afe18add2520886000787
8307e6db0a5ca3cf04b5877de8a9cddb096d200014d38772f808f4cc8f38aa24
07380010d18776f80700a8a4b8e9cb04054957d12ba0708f9931807c6887313b
4fff7c8bd028382212007fd23612d54ed7a0127bc80703000d00a894d9612417
c59dc6f8b192fa27a032cf1dbb271c75d28cd0b2a1b0fe278c1851c5f8a58e22
363b2127e8988f48190aa37c52fa9418f1a215f5bb51d2401664590f319b1051
e20d7009903075d29ff90b96ca9f5122932a3d0cf2580f241ba27e92a3a2f423
dca08cf994d3d2c44ede183a33a92de1b82ab6d08bf8ea273b81265af922fc39
54fa0c1dc290d2b4d2d350798e482daa7518b2c00a0013e1123205b94c6dcce8
f19542e20d302d929a6cca82720ba2b1a7f00a8a4f65556a8caa91a48c5cb5d3
c0e255a8e8b2ce885152ddd25961a8385d975ed5548c30932cea4db438b8e9f0
5093e02ff1e10e9652cb1a83d64cd5319fa8d6c38888b158308158076920adb1
f0b482e8b17095d36bf395c19055c5880864190769fe882f9d50bcb1108ca1a9
0ade94571c1525aaa80a342956b438887088060a5a07efa4ab9a59aaab78d655
2d58d3148ab991d2c02a0dfe9a8b6c40863e3800bf2a0023202de23c94e840d0
85cd586a14108a3a2497858adda99978b83a137c87700003060886e9cc922c42
d097a54f9aaab5a045458f250d70283f9abb8514881746b28724788405a891a1
78537f23daecec0dc022c4e12816efa9077078062eb0017ba3876f4882458800
f8a0d2adcdd401090c9a758a252b095683873f7880cb8b8018d0869d928c7275
3f14815b8f18882f3c2e0509002501ae379106730a843e685a25dc9d3193cd91
888d6df8077bd0075d9206703807d8690e02f9d2feb6a45b7985117b1a889510
8002a09a735d8f4e380295fb2817bd5c91d80790418779f8871efa26251c0701
60073f928709484590ac28c145dd3c1d08ebf4ab7028806c808bc5dad90f2085
f4200804118fa540a270e804036880796384b978c0aab1d37b3544672ddcfe29
88f83427e8ba833e18b478f002892c8f7da88f9418b6a40887cfc8865e80814f
100734e8830dd0827ae84823f2568c5d5fd3ac8f009107eb2c8f2981885d9000
8ad0ad799b0163489235e98961633c907008468a051318066ba8824ed0841730
061232224441df0646ca5b330c047b07ad110006682f6e129175e003476007f3
282bce40224f310a77f3166a20823d40842680fe865e688161909702a88a553a
5319d6d82ce99003d8062035a7f65a8f7a91867c1007215ab2ca0028d04b0abe
d0067d980774c8000b20067670051dd0069cb817fa502e2ce6dafc198878f086
6ee9e01a45b1dd99927bd810ad1088b6b050a378076c081cf7a08e7be8843530
9e8320383ece547ae00741de1dc42a09de19048a0080f19dc9e1aac9a2e09d4c
1000056081bc7cbb87c846eea011a3d5641cd589f9a3a1be223f57d0801a9092
5a0881ebad864ee112b3b85d90f8066ee08056f8863ea0837a80851218cb74f8
86788800dd70ae5bc6d1c5fa097f6a807840060f380476680769c0862d508437
ea2a735a89992c8a6e50861530866ee80620fe50064258827a18007a980787e8
336e7e527f4251b068007a400615b005717807697885617e23c35030781e8979
90061620857cb00735d884207884a1b0086d189a5d15681ce58e7660004a9a64
0178003088830df180021804d2620b9acccc8dc807a67db677a8042a58026368
dd0150c202d8e69226d1755007d6250fbf9200d85c82929d69607c8e29190bfd
450aa871b8376986112018abe28705a8078a9114a3265171529e190bdea36339
76e00673d22a4e4109233e8aaff807213a0f638900a9990e0340874b3154b246
4a7a48ea3d5a51135a5169d006373a157a0087117eb493a0ea46568a9f2025c0
9e57c9b0d8e1108c64b26c715d0ec1505efea4f08d701b0cca3eddce56456f9b
b3a0b091d3e615df10a02d446dedbc8f29c56c067e0a8cb9a24b5de0d92651ce
2153ca7ebf144958d0f66d835d4cc2f0340009eda2c011dcf033dc3e6eb6348e
2bfa52d9668c3f2ac4e9f6cdc3bd8860bd221d248d75a28a18e66eeac699f940
17c58094f83014dd20dcf3f6cd312d9461550cc038a443f16ef99e6f18410e2d
6cee7cbca2ca0e70feb6c04b8361ec460b58a5912f32f0eece8cdcd858056745
ac159afc797044c57082a00c0b5f8c074ecbb4cc70c6fc55d5651e0a8f0aaf9d
15e91ef17bacec15370aee202710a90b5443288510a26b78dfd1d4397f49e516
374dacfd890acaab300399182a558290fecbd8802cd780b823f3a96092807590
07e7b0aa4ef12920f7cd6b9800b79ab17e39368e9071eb00b433bb87eda82496
a09895203bead5f2ec047019dd87bc0a35d01b8de133bac4c30977d306ec058a
185a184fb9e9379f4695a58a49f5ce90311f8d483a13850770f8863ff0a406a0
804ae8f385f02b09760e7f192d426f550e9fb3bc43ea38fa4f240ba8b9b887dc
dd8e70480513d690743882074085b93800adb24eeb7c9610f6f4a3fcb5a1c8bb
1f31a8b3388921434fbc9215f758073d5083bae6107ac883c7b1999f8a4fd1e2
d35d9f6187f2950651a250232887b808732227f2e087bab3ca37c1863f688285
180c9d1b0dd7b676e2b3d3e60d6362fe1b0b4e41d73b898bcee8a40138804000
030198f503a8947b9160227e77a4e4b4c0c0bd1051ad18ea320b35bad8809a37
d6a57f288398d910ab0a874a0980b4fbf18307c99f40510348073ee7a6874331
73c3176fe164a8330774209e75b00797c8f8f5e09ddba2d54107f90b041a1ad1
9c7288875ed8801a48072418001be8a57a198dff3c129e952e4fb8830060839a
b7219c37f89d475e827b070af80657000152d00509008277300336a88b43bb88
015d3849f5851b98877200811f0807297004aa6c884f76489dc77af71bd70528
800ad883bd41873f480471500527580799a0d082b007a4f227f149042378fb18
f8056458052500eb6c2cb08fdf7bfe5f850f03b00674a8004c500271f8862e20
04718004c4afa41029885245b97fa8042898074068036d0887cbaf4186dc7cbd
ef7cbeff0b861208a829006c20015288061740820410814ff89805f19148f520
2b08802678834d3886137084dde7f018f2fddf6f3fd21d086968070ad08757c8
000280047b8887efeb206f9fac7f40bcb120a767d38763a880019883f34b6ad8
2a08aa068875ebfe112c68f020c2840a17326ce8f021c488122752ac68f122c6
8c1a3772ece8f1634279d7fe0528184e00807affe8818b578fdd3b96efc41984
f72fde3a9beef28d1bc72fdfbf71dbeabd0bc02080d19205053205e9f429d4a8
52a752ad6af52a5688f20aaa43fe1a40808003efc2c50ba7e100000148debd23
6a305ebc77f0b4add3a7ef8b020171d8b18327adabba7704036c25c85460d6c4
8a17336eecf831e48eeafe6d554aef5d8277e08a4c40558f251839d6ea813348
ef32d175df729150b62ec9236bdb4e00133cf8e0e1819177f3eeedfb37f0e05c
09162e79991d004a4566b203f7ac9292d1cf0ceeb3f78f5dbd75ddfec061f7ef
590d63c2845c237c1b7753e1ead7b36feffefd4279ea18dc7c372040a523efb0
634327068e38a41da48f4b9f6d174580e6500204295504f0ce51f29434d952e9
c1772186196ab8a16493515892000f1e104e09329472c0576bb465db52ffb005
0f38e6e4028231f57cd38c10fe34c811803ac525642187410a3924914196848d
8b03dc540b0f2bdee4623507f1030f3cf1e8031495efec830e250038a2d46406
50582499659a79e66e858d44d24affd4e3803cf1d0e3265bff84e3a24a4bf1c3
cf9382e144653ce85ca7146506fc33269a890a290fa38529fa28546396148f8b
00dc44298b2e661a143ff5dc23974d04c2b38d6d0118e0159b90aaba21a3abba
fa913a93f188225802b878509d0769f38f387d6963d34df910354e36145056e8
a1af2abb2cb38aae499c012ac115805b70699ad038d7d503cf3802bd738f3bf7
f0f3aba11f128468b3e9aabbae7b8cc64a929fe1a4f4ce3a986e5a90bd378d03
4f5be7dc03cf948492e428febb051b7c3064cfdef6e156e826d40e3ffbe6134f
96eefc63d33d0100e0d53513fca330c2218b3cb25393291c403c1aa725c040b9
2af40e3ff57e0ab361f0ac73cf3f9616a414c124fbfc33d015c94a105b066473
2d43d9da430f3f6dddf3e73f7baa434161ea88e970d0596b9d75cf0f16a4b344
7b2e04b6845bf58ce19e69abbdb6d85bbbfdf646021b7036436d23f40e001b27
952cddefb1fd77da700b3ef8445e9d2ab04600009b2ad6f0010e38e1914bae90
a13b276bd16485e93c520023f5edf7e36c4f3efae83c268bf8445df7785ee3a0
87ae36e9b1136e3a65257dfed0875e4d505ec3b7b3f7fadab20bff7649481d8e
d1b3f35d8eba86c0c33efe3cf441d3fe0f03be3764db56b6ee4ca1f5d17bff7d
6402339fd09e82657e2b9fe7b10e3efbedfb36bded0ef1e30d42007bc3675248
b179befbfdfbaf58f1bc421f8700ec6307b9df940606add6fdaf810e04099848
c2c08248ed26fb3814cce4e2a2f8a5ea811efce0474cc7a8f12124813789c605
5dc42f1779ec581104210c634811fa50883e204b08c0ea05977d5ca369727907
8a8e52bccbc9b088465c48009132c08650e98449404ade6c300cb604a01d0429
cfb98ea8c52d4a707b0fc9613c9210084a35cd13522c8a4148c8c5353ed03cea
63e23cba410f16fc621c4019c7315cc08c04d4431a83a1d004d9e81b448de986
826c4f000026180134fef1346c79873e6aa28f79d023088980643cc661891a58
a30107288012b318c84332c6430621241149d99e7a30002c0018c000f8f12778
b40367e923c838ee31316420a1010128800268500d76a08c526c2a4cf754a918
0a25ef5dc732a4327f531402f1631b4afa139fcef18f5d2da51ef5880738d0e1
8ebe28031ede14c03ef2e4c66802c79406dc8ae7e4c34ef6bcc30014b3494900
460f7dbc8354c6244836bc198e63d0831d011a0759e22180b61c8a01809c276f
5099c5353913a2c0b90723f9a58f8cbe031de8e0d73bac531078e8c31ee1d800
040e41146dc86362afd49be94669d1abc8d364ee34e04c83a30f002060000630
4001f8e58e4c1400fe00094846a6c6618f6ee86305be5843018e604e6f2a4e37
8492694eab4230791ce55df2cc6a6f76aa8d7ab8631dda50012ec801824bc4e3
1435508641b4610f6a94c3a9f09887200eb00063e06d1d73ea2058d3242b038c
e45481fdcd3e14475678f42205dd20470f7e31d71af822aef198473968f08b2a
0165161d18462c8dc941ac1ed6295fed4a1a4bcb905661451d00e8d43dc6a180
3fe4e01c41f0053ddc2a0c83f0431df988060cb4310eb6c4231a51035baaa0a9
5aaa307360f2f11169e7c95aace4ed000610400104900903a025003748469e08
920e4e5d8c5bef9858a50e1022545d71b9ad15a5c0c2145de926861f00108c40
0cb00f7a20e991fe0c2dc839cc3a8e73e4631dfba217bfc422daf9bad723882a
c99ad6d960c668e30070a15200f2418f78a88328def82f41c411b175d0620405
a00152c7a1826238801d7f9d1065943b6158b9f31a3ffdd804243ce3c48c6302
fab8c6be02800e1e14d55437188a4188120e6c50a112f12045047c71d6603480
1da2dd7162287a3a878e44c6588e0a3c04500eb98ca319503804a94ee3091a78
a720dbc8c73cc0f182cddea31330f8050aa0e149501af6a15f8ed4b9aee1282f
ff792aeb08910308500070a4001ae2a0173ad2618364d4641ed468ea2fb611c7
4904c106cca0c05cce93cc427364241e6a18a9b1428f02f0a357782c0220acf1
0e6d7c6314e1fe390885c6e006ae1c6202c070a33c2a67b654135b51952388ad
90e04a001cf95ea86e6f848903d86253fb4c9d2b08cb0c431052654a24a7fcb6
57d8ebb96a939b4842ac558bfc9b1074ad8e7ac79210f7465dee79034784ffb0
d540a604d24c29ac9005c1a2e5084def810307008e0ac0d108d25b4d6dcacf63
32d7b9c444f089c3472c99d3dea126a3eee17cfb725d315ef1aa46f1910be7be
7a03cbdd5cf6ed872f2fb5a92439cc77632960613c8b44c39dcbdf18f39d4746
2ca5ba25e67c74c517f2bce88cb9efada6471182857b880c363ad43962720122
afbd3c635cd4b37e151a12c48625047a43e0c941356abdec21e41eea9ee79061
132ad84f37fe3bdc211241a5074f224ddfdfb1e2ae778e24d128bc55bb4320be
bebd133e23ebe460d4001f3545fa291ee26a22cabc58f8c90b2d6771ca09002e
28364cddcd84514b560ef7e1b5da9d4bde9437fbb00d62ab1ef143e90b691ba6
f6b48e3a89debac63b3dee17e2ce1ec9032530b51bd8470af688adf063ab1f8c
a973affce19c0c66b29a1f05a33f521cf24b9bfff086dc52bffcd39fef5df0c3
29131b1f17a2c0234effc8c901d8feeced739f88f9b4096121e2c37590854e31
93c73abc617bfde998fd93276449e48d5778de2d815dbee8033da4c6ec1145cd
c198ffe11ed3dd0a9b781e6fbd054ebcc43f80833ddc433d6c412fd4c3a32940
1abddd03feee9ca4dc12d898903a34cd41cc890f85831a84880158020924005f
15404148c8cb95e0dead09e76cc33e44d200c0c38625502401ca5b0c053d98c3
1f3c014cd0c33af0c31804c23b10c0a93080433994e9f120c9899c04c1d40078
c385f516a500cc3fddc44bd883339081223cda86bd8318f0c17ec018c071e1de
55149bec03c0044027b881e7155fa62083d3a08321ac854dc8c201dc4035c8c5
dcb59b1dea1defa1963d50890118421250093dd8c3306cc23f94433c6c834190
c57ed4033678415101800464834175941ba1d623f6606ae9c39408401918c000
10825ddc411040523b640a5cb4c536c4833dc4c53bc00508d6833d04109b08dc
2b929cfe9f81083a65031270823a20417505c0213c92412c20fd81433ef0053f
84431f0cc00224c3f1e85c33965dd5e4933e201c0d0c833de84313f1934625d9
937c133d8443d304020eb4832d74003060dca1798b7fd14b3a1addc1c9433be4
6301ac483c600995f00b501404bd14083de00829b0c31808023ad4431630c2bd
19c6401624bde8c641c29ca410040386433898245b90ca409c6131ba09323e83
172082388c411a7c433b648122e44cada01c499edf49f21ce718c500000003d8
833decc21210df4bb443592cce3fd8125bd8c337d4020780022c1c01381c4202
2803001c804d640fd16c5c51f29c0eaa834d08002e50c00d780200641723788a
3ee4fe84414064bd20a02b3c40010cc0012c8179ddd73b8c8400504841a625cc
3d8bedc4840494411c0408fdad03091cc23dfc0b5512043c64834b7807386003
3c18541f49433d0c805ba843cd25a6628e9cc9548e8b3d801774c736d80338f0
8322c0419d50e5fd5c0a5fac033620093b8c86349c8031982610e98f41a0e56a
0e1cf75ca19549402c40c00214834771430c888296e0444d640bb8e0cc3a4843
0918400340c23f488310a0420224e53b4c46cd31dc72921ced1c802fd1c338f4
42073400772102ccbca141f80488fd432024412df100158403182c4269e6caf1
51e47b8e5c7950483804c0d3e484d3949795fce702e297609481217c0a3ce881
0bfef0011c24a86db46783c25cb99c9f005c492b6c01bf905f5de483ca65683c
74ca3b080214dc033b6c03365082013c413d1c00a97c8500b88bb491e0891e56
71e8cf3b08c02dc0a527b89222b0c56506457fb6c5c4340d3f34830b24015180
534702d101a41f60255f923267b9044004084017a4c18ab0040928025f4c687f
c2c33d10d8c5eccb435ea63a94c52301c098d84a9d0c84499e69b199cb9a2c40
3cb429afb8d837f4011c58839521499dc6039e728b39dd03812c5e9d1cdb3a28
c57a12a5a1925bac5cd588c4c203008031b0833a34430a940276c4433a55e0a5
94d72315c60a018c00640358d857f1fd43c28d2ab5f58898988abb09442b8ce5
fe5866639d04c65bb0c5643a09c0d84c87c9039f8005a15acaa08aaab0a65ae6
10ca57d884187e267314e3eccd6445384a8a62dd0e76eb97ad656558852b4e86
16da9cbb12db55915d08fdc34fd52192de2b7d31407994c41241c5c1d14edb81
1fc07ed9e1e92b47acce12b9a2c22e2c96890f556899c5becbbf522c2989cf16
0a4dc328632b72ec97cdc7c749ac55e88fd07d2cc946d35519167351c6d09c0e
c7b5ec613dd808be97ed102ccbdaec1af920e92945ff9956de9104528cd0faf9
ec4ce12141481c7b5585297150b099a9d2e65445d99b84306346a08b0e1a90c3
56ad20f14fd719c4b1c96bb238d46048dcc682ed07452db8de5454b09cc8b2fe
2d584520ffb52b55a8ec60f42cddcad0d0988d61f56ce048c994c4643c88c339
a083348c953bcc0323b54569ae4369e06ddf6a5144be433be8430184c30a0940
d354c33d7cece05224c0f0890eb9882724250ec828d29184cea0d2da56eef014
1051444376b185376c2e9e64d1a88dee48014b42450201584030a08320006902
2814cba84303849796c9ee16c18328da07411c402c0980b5fc6a0eca4ff069db
a5e4c2036c023be8433760030b14a700d003bf648c606859ec42afec245492b0
05030a2afed946a8ca5f48bc053d644210a8c4377c83255c0031b08304808339
3529b04814fc1691ace61f61b2c5aa51023710c59c68a3b4112ead32045cfee4
02079402380901048042809c443a5daf3a249f2336b00ce5c335f08ba578eebd
99031430024c10639da85cdd295cf752075c44294ab801a654433d7cc58334a9
41f02d0b47cff8d5030084033d840803508204208137bdc318300237e0efdff9
aedd24e7e75d4a384843a788832e8c8000c4403200c0867de98428f11243cf40
0429bd60033d640c18a8811870d71890002328a7e85050f7aa1d4bbac82c6800
276031108cc30160e0a77a611ccb904da48c9ffc8358180126ec43615201002c
0106db4620f3f0f0d55d3cb40312f4c124a0803588833ea4402ff0d1bd85c841
785b248350cc28d451b4c50184239e048a7f7d18e17af11727dee8ea43fe3ddc
8110bc020c10032bbb4027240002284029f3ebfbd6f2e4bcc3386c6e3ee483c6
7802672ee03fa0035b70c3cd75f117fb2e31db8d8cc2c207dc020fc869279441
3ec09234c8034d3820d35af3ffbc8337dc97a6da0336180148b6a437bc44a6dc
0b0f77f1d701ddb6848317188060dae91dd98a37294fe9e9f307f9c401c4ea37
50020330413d84033a78c12258c3adb088f50cf342f491066287cd40ab1a5c43
af6c0cd6692d460bcfa161c602acc33374811d64c102484017a440490b0632e9
2f44644769a8c49c10053614012444c002dc893a4c4035df34dc2854810cc066
74025f44c31014c013d004e56a844a081838dcc20144c13bd4da125cfe403d08
cae061f5ff04403e4e9500e863ac42e17ed4ec47e4043f4c122d6040216c0205
48413bac4028004037b0098c5d355d8f0c200595587883addc8315e9c6a7f4b0
47308d4dd84326d04039d9c3293440049cc1005080167e6d644b8ea09d0b7bc2
b050fa4960a81c5408caafe8032e94403961122308c300e4032039606b7b8fc6
1ac00513213824012c81851d3cd2193e053ae4c4671b4200d0814d4c4c3f2989
d7526d71c78e7c3c9490a990009c020e90ca3fd84312ec22ba468575fc4a60db
c33e4c09285ec93f20c0b920271c7fb7cf7888a9a8c336c0430098b730d8043a
c40308f8427b43051925d018f28995fcc3004888d3da347f67cd33fe86b30164
8600a0c37a0b863e00431008034247ca6e120402fdc305d1b4e05d3878af8e0e
fe5851ac683c8cc17d80451db0056777043f380a0b2a9cfbd91c6bbb78d0e0ac
cbe906603fd28e6305feeccc0b413691af8aa4180afc61a66e4c090bd28c54c4
dedf75b9320e0c9447b9940fdda168cc3f34c0e2e910965765184785e6413831
270472921e4ec1ad9817f9a148dcc5008001804afaacb92d51c5e88acd9bab38
65a02dc370c57edfb9abccec48d8d78b309ea8e24c7df1c93e34f8939c874311
8a8533bac10cd1bd297914ba0ced4dc5394378a1538aac984a84f999a76b0db8
7e85a89f6bcc208da9ffb94a23c47f5b4eac24edab4b366050c8fe75fd432fe6
c43ac803cc48fa926f44dbe4fa2c7750f1b8faaffbccdcc05849d412c414d0e2
f9509b3f8670c5f7861fc08611e63066e6b4ab0b3f5ffa0ab61ea5e40df66208
bf78c3a149a877c243eb52fab9a33baee54cb2cca2893206677fb1bd0806ca50
494eb7c578e5bbbad00f19d14fce2cf0aef246aeab1d3a308dd394845ce47543
d6c3442a7cb354f29ee8a0a570ceb233f930ef703e86c39d8a0b60d2c7490c84
c37b3cb3d8c6356810c68fa5e9983bc09fbcdac58c3da4c33dac437619745978
2e37c93cb334d1a1bcd648d1b4c4075f2083ee3ce4032626e397c6c37d953cd2
9bc90ac2439f4a383f5c3a3f28095094b862f4b0da95948c06fe0110dc04006c
033f0880a148e8d6273d9fc8c36b6d4c3c7883924492963f86b38b2a0a510338
6c400410400270008963ab308edebed73d9ad84c410c00883300d3cb68496abd
542c3b5cb41500b441f9d50313bcc10050b495607db23417e4a3093f5c03a550
be3c5c10af0aacad97f563c4493cc8420420c236482e3d8cc11384998eb243dc
635ce62cfaeaffc63a5c907d441e9508803d24f2795d5fae843946e8065c6482
0f50da67ba4208b402fd6d3401108034b4a30adb7ef267085c8cfd9b698c3614
c03708020028783aa89bf55f3f4190453880c0209494112c0040107a472f1e80
05efb6c5d36740debf7fea1e3a94389162458b173166d4b8fe9163478f1f4186
1439926449932751a654f9919e3c7e03dee9d3070f81806f23d68cdb56ee5d4f
9fef2cf2e3b7f2a2d0a113dff183b7ee5f3ca7930a08087023593d3ce73ad159
a06d9fbe74ff02386c28af2151b367d1a655bb966d5bb76f41d2fb0700c0bb7b
ffbc1508e7654401089efe6d1bb3ed6745a36c0f2315bab469b870ebe0fdcba7
2f17050709e0c0ab3b9781bab011e186163d9a7469d3a74bc713e030c0367e02
ec818361291e9f0034f03828f613e8c4c46a7f4b8427741dd378f5dec1f3866e
9a950231aab1bb176040027810034074a81d7577efdfc187179f169e80c9ef16
240860ce9e366dfaccc53b33c006619fff7a3b0c8e9addfe3f74dff870600665
8450a31e760e10401da01a5270bb8a7a1a4fc20929acd0c2b320e2ce21041482
671cd5ec09a2877af419479b77cab9460660242aab42a0e201830136de19e712
00a071a74600ea91282c0d91caefc221892cd2c80a21bac6c771a2c927b902ba
3164861eb829111e14417bd0c2781684279c320c28008104aa38279c3db41167
aeb0b2fbc74589223c52ce39e9acb32ded940c609c001aa8a7bc655c18440b61
7ae3a647899454d2c270eaa9271c6c8efb679c71d81127970a06890000fc1c62
405108ed0c55d45149ed483b03d489a727bade11a3886ec000c51a7dfcb043cd
37b39c709c7adca1271c78d8d1071c4ac5418715098cfe39801ba0de0100d752
a18d56da3a3374f39ab0f241ae007a66e1601267fe70c41a74fc90c11a25b57b
56c277528d671cc9ecc1668305eab0a71923da38a0a7030ef8e70020a70d58e0
81c5fbd400b00cf0b30073e8492e1e4a9220d18b3aaca908e0f1ea89073212bb
b9058436de11440002e808a19403ea7a67d9cf086ed9e59747f3ec1f25eb4900
007acc31679d7ac4b987880700b0c09899ad2df21e77e1a9671e6a28b1209973
baa1471b2d182825e508378559ebadb946c945968112209e4c0a28000026de41
c78b198861e71b37ab2d323978ece9069d0d1289899e71ae5cf53eb0b4ec5af0
c1bb8e7b229985b3099b181081079d210478441c76fe92d2674e9f3c5cc79d74
2a51208145eea107329ff4a50bf016094f5d7581d17d084836c312009d792a61
c11876c0617a0153eac166e739918be7b177eac9079d4808a986c470c621bd5f
1fcbba78f5e9a997531d79d4d12e7bc0150d20007de879250351268fcd8c26fe
a12769e09b5a879f9e64828c9f7aeeeafb1d94814a9201371f52b7faff012821
17a9a37b030cc0fee0218d4908c00ce2a887379060877fc0e34a97d30f05e961
0f2751b029ff58476fdef19900ac4600890ae0095128c05c01ce7b6e324072a4
b10e7ae082020148c00208308ce1ecc31e738ac73f9043418538a9270a89467e
1ab49aed802d854d74226934b43d9621ac4b4eb9fe873bec810e0fc4e076ef90
6139e624979e28051ef1c85672fea1c1fc49c4009f294b5884f44439ce712d9f
6a93761810962bd9c372ef880738c2a18d4625671d7791933e202311bee5231f
4ab14b3e7e381179b8f1332f8c231d3199c992606f3ba83adde992960e7b6483
6f8404073af013278141641dcde395000a308046c5a300bf0b9c267199cb8c10
e44ada62ca5c06c0a37f84e37fee83910006c08f54e18501f99888a23ea54b69
e6d272d9201e0096f24b001ca047915c9dc6ded7bef7054078ef7b8700c8324d
75aef3871fd4570cf183cd77b4a383d38b87399d49c110ee43339b8a4758ae61
42ffad93a027042737cfb91a7500c09c1ea4defe3d7b02490ee6c300d85c473c
a6b3bd826e948ef2701f8fbc980da90c87780eb5a737220aceb009c01bfc78a3
5834ca51999e50337f3be00423f4cb6fa6327df1b8123fe2818d09dc4f84449b
e95101e80d8686303b0a9da043b21119ea8dd11bf1f80a3cb4015401ac263f01
6888f4901ad6ad3114a5acf12aff2e58bda40ce71e7799147e46383f1f5dcc70
62b5abb4b4c750d0dc54224639caea80329c7f1c0d32653c62b37ed8c23b6e67
2c46bdeb6343c59d3cf103006159c767842414b5f2e38347bb2772c0d1300716
c08dfff0a4f66e0959d5cee9ab80bbce35b62a0fe20989a45355ca60f79148a7
588206ca6b13a218d0906b8075b5c5bd9070fe59a31f87a80688639488316dcb
0f7a646b1bd940072d3810055798a013d6f01477ce0a53b41a97bc17cad0241d
c2947d08601d9c880372feca944b126e384e016d2a26600a6b80431254b0863c
f6d742f4c67485e53570784ee5a61182251cae084130e0db1ba61cea9bc46cd4
3dd0910a0f18c381e8c8c3182af649ec4884b80736316a64a6a8cb0a4f0502a8
4384d30b44ead1432eec60073a9cd1054458e31ddfa044026e0796f0020e55ad
3df191bd4396834dd17b95c0c43a96d084a44858c6f6b4874fc7c10f7b94810f
a9ca9428e0610e302c411c097887489db28ebac8e38747293192e16c12785c91
90faf0e9028a878e0248a359c4ab873ce8fe810e32e0a01a334846fba4ba3aa0
ea4329de1056080620001c4443392840822706808a03ec8f98f13c0abb0e57e0
388f5a2427bac7dcda41516f70aa3c02408e43bc080e000de00ddd4ce4f422a3
0f67fe431ffb500a3ff4810e7ac0420b3db2c40daa710095b64335ca79666a49
1d6d90bcef1c923a51337de513015062016e204811d1018e596481721a4b74f5
daa94c897062ab3730c63bc2818452d4232c4add87c60680a807bd59dafd86d0
b252f5926eb2f41d06e88410aae1c77d34ea1fe000c73f6c0c6f4e4d4f1fc901
ea3f8412ec786823088ca88d228a67ee7af06b29fb900736491c6a7faf7c23ce
b573ca94229579506113c85119c39de2fe67a8ce57708c76cd0f29a80f7b2865
0b8188874be8470f4c00c0180e38c03aa4811f75304099adbb1ecbb1ae117d4e
672918a5ac4d68ae8f6be0811d3d7a4c438b33f1d50d871ff9b087af87f2eb79
8ce010cde32c36f4310b26f896b200387ad6c49275c15f24b7493b003fb42180
06a46300da58873ef800cb00c0411cc14802f322a4520aabeeb61aa7e0afe331
8f7920a110f768e53ab2450a1a70c30007f08654f9f1a3810e1eeb1abb5f8d22
938f0608806f9c101e3aee70bb45c4618291b93774a9671485f0b3bef4d8475f
655102b3f16bab8c703ac68d2fb3c6468ff6fde64ec061120fd1354a000f8884
01cc70001580c30d36c8820d12cec1fee70bc52efffbab669d527c5e832110a9
2ca3aa8807555a2db9e02657eaaafb0c6c80960ba460491eea8100d6a11986e0
13c4e11df48002806110eac0c6ea81b3fe61fefe0a80340b0429420f02a1ec3c
44d710827846e8a2b4e3b79e4dd410d0b880e41a0ae01a1a65295a2f639ae108
488172c0211370601b1a25888c0fe3000846f003a8eea9beec811e94021b4a60
de1803d6086384d421040f866814e5006790bc1a8b352eea1efca43c02207494
0e02082536dc6011cacea160e48754e9a12802ff940b9180c00deea11d28481d
4e4d28e2c10022a385d4610b6f89dfbe10a9500bbda4c100fae41d06c029b2f0
a2024100e60d1cee60112a101b1afee6d5e490e7928f1fee4dffece11e2605f5
eec143062b2980aa1d2aebfb7ec4ea662f11ef0a4f3e8329da017f9ac243aa6a
1e2821681400d92a90c69aebd34cea9b22e9927e8dd7dec11b2e2a1cee23551a
a2275ac8a8ae459268d1c49464c09e0a2cb8a99ba461286283783e68902e4a0e
612db01e4a0e8742219a7028e6ef4aca616f928672bc448ca44a842062c06631
1bed2a43c2a221026028c8a91efd031dd681301ca20323c3e5fa284ece4da63e
a4f594c28cdac100b80132b2ac091da22179aa3840d21f71a9382a2839204289
52e98050cbdf98825fbc48cd1a8502208a5d868383806259d20b24754a24e7a8
38f861d5f26335d0ab27da68bcfefaf1c050aa1d28801e0aa07962623596c5e2
28a86f284227795293b2013fb8e121b243201de279f807110f6cb654a3003eaf
2956a351d6211b76b22242f22ae9485198650bd12500d68c22a289d4f8a11d74
041ea2626fc62101b6e11fccc31ddc6728c02aede0528e32e40567c6003cd000
1820325a07dae0aced9c441bc6c11e02601d10a0882ecb1d0a1075165397d209
bd08f0472c422cc9cb29f6611b500a7c000026f24174e021d2f40d2340b134ab
e7053f0322fa09e33c70f07c65eb2668000ec0edf441003ca410b5475de69037
4f885d584635e96238b2b2228ed2c07c8a82f6211ffe102c28aab03a059a528e
a7a41380b843b66050895286feedda92e5386829e8211d1a8982901334dee11a
f62737d37137d3537038491ef425f008f36aba91f622c3dcc2818f5a01011000
d394cd1e0a142c084c49003440b5461ea2e95a22446c54c32e0b233b072f63e4
b08c0241047a411aa8a014c4214178a33f8d4a1d222322359470c8e21a8392bd
e461090ec13e3234dacec1dc924313162019f2c11cf280621240017e425fa628
2238e84609673d034cc2b62a1e50601678e318b36e1e9eca1e90e105424169ba
e10816c11a98001960a2cfcc2a7bdc674aa9b44a852c22948530c36117428013
3a60377c623be30c1c88671fcca1127a403acc410f68c018ea811324a0181c00
413b45386b724e71f4acb4fea35904c031f2af146ea01eec0301b1611bc4811e
9c8112e4c01aec8115322019d8211ed0a11644a014daf47e244200386b312c55
4019c22be36935c22119196109de81118a8135914c48d42109b68a0158c42190
608402401108e09c802ecbb609287e697b907557c5e30005cb72b6610002e009
df276b22401f9e011bb44009d8211fb02a0d04800d1ce85d686f8d9ae2de9e2f
5a198013dec199842201f22d585f222994683d1dcb5b8dc4eab8e32c6f336c46
072c00400c78201e80801096201df85019b0c109202178684fb6fc531d380107
02ea1d644b1e98e70984c1effea927c6e1b20c895b65506191047b506b38566d
33085328d4a101fe6100fe96810a160014b42109cea1024b2929c2c172062f3a
398913902043328f1e2c010094c1cc02a0f0dea78d62aa5b6db63b06485186c3
25d7d29de4412ffea11a586104120011b46109a02188fea11dda41319fb637f2
f21a90c00dfc0f5eec811740001416e00084652e92421e0ee6fbc2d6488c6cb9
d4aca4d8eb4ada681d74c0087a841e6a210448410992c10327432ee454f0a273
220e01004a618264c81e989500224020be0781224366bcb07129248a20621f06
b2be10a800e2211734c0130641004c611dcc8112064009bc8898fec81e66eb5e
274e4338e9b9a860ab4a618c7ac97ba030f6cc2a616d7748ec283b20111ee8e1
1e0e6000a4011cf800fe12d8611b26c10286c1e12041ca8255757f88e110905d
3cd0257e8959280107a4812ae5b01ec8f5609c8a00bf7748a6d739816e53e8c1
00066000c2e11b0ca10e92031d06e109186e74182939c6c1c268d1af2a8212a8
40809d24951a85010a20d430355d48338143a331b5c4319bc2910ce06034331f
e6011dc8141ee6c11996c014c401ea92a61dd2e11e2a5255b251b32a021d92c0
821963b686023960c9471ce21a8af28acf136c619824b2e762046c6b47a7011a
001934f31ecac11e3461037a211d9e610b1ca102b1aa51cec14998d046793255
2ad15f7fa221d28ea94ee705a3e896f2b28bd5e24d7ecb2b67f35fbb331be2e7
6a3bc11548a018dcfe219f92e62ee24b3ad925b41aaa6ed76ac2468c682aa94d
a289c00c792df0a44e3fc97be6e61fcee1d426c58cdcc11b362006b6e1f19c29
cb7a83a482f40b61e457f881301809cbe0e11a0ca91a27802254922cb4a7764f
3925bad033fa3394612b00e6861feea1dab00af5aa8d52b4d583d6d22988b4a4
78130029c87dbac9f68ae86bdae8ab7e7302b84f8b9f19435c877becd97bc282
fef043b0946428a2013fc8d083555126d28d9c79d327aece7df2f56fa797af0c
912b0312676b769e4dc233541335d56102bc4a7eec2239b4411d2c871f621688
f6a14bc8a82900b0837a397f11b3fe0aeb5f9f70747da41a5333200d94a257a2
1a99cc7b5c64a2fe48b13b8f42888ea3474607e734268175b9ebdc0141d8ab51
f24d83dc05022ed9cef4a9a7b615a7718a1d100f1edae11c9e1088fca4790260
2ac3c1d590231c14406c52118fb1fa237ea81d1a4d5b6fd301ea416c088239b5
a1b2f2a11dae799e866990b9383d09e91387a827829330f9061e4ac7817d259c
da9a24f8281eaee1a71e651d2a65d32063a1ce391e28208862d6afbda90b9f99
0f3fa41cd241a43f2492bc6a4171b527b6ea7d32c63637efb141a23655a551e8
8112d23a01408e80b521dfd6729cbce7f5fe0f09453bb0355988ec6c695bed65
61a4350000eac83219697b24caf040f28112242013f8c1122440171c08010800
a521d18f0a82fe36c5f510471b2862761f7a624cd6215819c01d90431db66a1d
be60018281b0ae642bab5b243c3a1e6283075ecc1b90e10374c11aaa4008882a
688b081b56c311e1f5b522e2ea4e592e8228eaecf236cf991e1a801d068001d0
41b7178051c5cf984af7bf5bae27d0a11bde97c3fee11548001ac8611e764000
0e61e40600ab08d357fec11d180000b4011be7f9e19203c0b069a4eba28c0460
018225164c6010388014bc884be88f9e541c24cace1ca8810bce6072f2610c98
401ccae11b76c00834200eced73ad60144ef21616e53f6b05ab60e6020292bbe
ff89fcf46001aa2036dc671064004839c890b2bc23861a1da8210f8200393861
01da661ef4fea00584998822ede8589023697a35030fb9e30c60aa859380934f
5271521840632e8a01f4810416e0133aa113de81728ee10306619022a4d30a9d
23fa281afe6304b66a0110811dece11932a01082471726805805a02eb6c17031
bc4d026071f9677a5b84fb385d1b41e37a0cc73304e0d5f5441be0a11c80b659
24c00f8ca058d4213a32061c2241009e200284817e84e7d63b021c6c8f4420fd
0584a11afea11bc86009dead27e8011c9c200018e10107402f54052c219a223e
5d4b0a79f0d269bc9e290092f9b6fd32cbec81011a6001b6e11bc2c00dace11b
de6172e081a08d00007eb03fe25dde39221ef88c7e002969de61553fc00caca1
6fe2e11bfecc41173820024401000a400202e022ddc457bd272fe3d91f1798c4
1417a002407d5c9b30b72a131c4018b0811204c018e8811306000e86a21deec1
1260601b50701d9e8fe535c2b93c489fea211dbea1081e6000e4a03be1e108f2
c801a2a0032f0a615e6aaf6c7a25878b165d18adbc671f1da296da61e464071c
500000048001347109624900c0c012df304ed113edd37e6e084229d07887b1a1
798a455e10a014e28778122e5803a01ef2e87454136118fe3cbfd07068fa3711
201c28e000d8014af8200ae0e1ea138077a8a11ed6e11504a00928a790bc281c
d552f333025ebdddaa4ecd8fec6c1dbcbd1ea84110828008ff089de98746df05
3b7e64fe02eca84ee30650fb8d43152c2c3c4949b630d2b2e140b8bc0fa240ab
b1610d98801dcc611c8c4000e2a0ec00e2ddbb7ffbb2c18327f09fc2850c1b3a
7c0831a2c489142b5abc8831a3c68d1c379aa3a70d1ebb73e7de1dd4b6ee9f40
7ed3c8f4a8f72e9e3e78fcdedd2b69329cc200ff0cf05c68e09fba9d0182ca53
38b4a3d2a54c9b3a7d3a9441809f3b174e0de00e80b677e9ba759b6481183b6d
af52a46376c2083b7602ebd5fb472fde3b7ee3f8dd7b8a37afdebd7cfbfa5d97
2d04034e878a094cc8909e497ef1041c18f02f5e0178f5dcfd2b308e5e030602
c62174fb8e1e387a0c935e138ad4afead54c93fe2b17af6ebb7a34e3c58337ee
5dbbfe7b000e0018b72e00e87505d6bdf31d20debd958ce3ad334267dcbf7655
0ebd658d3dbbf6eddc9bde09e046e5e186f9fef1a3a9f0b80085bb011cbca76f
660101ea047aa3a72fdabbeb428f0e758d1a80dd0da8973a4725160e4203e1a6
9b41fc1cd0403efaaca34d6e01e4434f36fc00e01e3fffe433de3feb8ce84a08
9cfc53ca01a5f047608b2ebe08e35223a6271e620bed331442049907c054fbc8
03c03f6e25e7193d5301c01869fb19f88f7feab8761a6a314ec95194a9c5a312
4ceb48c3cf5b020800804dfa0475d03601e8630f98039cb74e34200e84e579f0
c4d3099800306213957aeec9a78b33aa54a343fbfc43133f43f1e3e13ef104e0
9efe78021cb44e03fadcb36151f27803cf42072e14e57f7d7e2a91a742e9f3cf
3626d134d5a3089d2997005cee178000f1d4349742cb4516274de1c41922a8be
fe0a6c47d968fa0f37bd2e541ea2587ae34d738402f0e554b821d4803b031df0
0e375fa694149307022860b07c2675e072b80567804c0284f44e00f418074063
013c36504ae2856b5e438771236ebffefe5b9a42fc0ef4103d987293cf6df064
a3cf39e785635c3dbe4d76805bffac27505d572dc4a43aa7fdb729c0545a3994
3c30412b2b96f00439173cb216d0db5b99c224626e709a87a88758fed3ec4236
8a0c74d0546e4af043fa9c67533bb829f716321f4870800dd5bcb30e98024926
fe1e3c1513f51380210b3de5b7012070006a0280b34e9706cc340e000c80f38f
38ec1c14cf39ecd0e6d940fa3897b3a22a37a9b287600f4eb8765f170d514d6f
6d098f3beec4a38710ebd493451cf61c8d0002d0aa745e50f50cc5933a5785fe
75e1041e55d4542a8569127193d6c3e1000308508b040174608c49d2e4730f4c
e348f7cf5deba0a7a98de7998e7cf22eee836864e7c983ce3c245c02cf3c88d8
618e3d224480c00dd5109080ac01c8e361e855fd33ba94a27a9d5afb526a8aef
e901727ce051df42e41fb1566d2cba50edf0338083c04302f6a08001101001dd
d0e2034f40c2dec683a5b9ac2382c44b0fe272a6bc0c6a90351ecac7f098e6fe
8d705063143348063ca811853e98830f4da01a18e6608d6ad0a3000df80dfa80
f28f28f927005211903ce4d12dd45cc37eef735ffc0624aa869ce62851fad843
0474954d458927f9e007043265000104a01c1a28000648c18e7848a3171ad0c5
9b4cb510c12984268ab260641482c10dca718e4f81d388e2510fb6d0831aa750
8238e0b10a0bf0021c2840c53bc0f1073858e31d45704135ea81809fa00e2992
fc4fea02d0298764727e21b3d28b9ed4a4d484ac640a71a25040c990a9f8a421
545187018632c1a9c4831ee300411df4910b12282334e048c223eab10d9a58ec
36b49a951a6994c6e6d17199ccdcc840f8b18e7dec2726dfa0850892e10dfe28
c8011e9aa08138f4b18c2228421c5de9c3022c1084d10505355d63806b802815
d5e530944d5a62fb92c8241705f11a413c656a8e983ef551c57ca243c0972650
8f76d883173d48863ecc618436c0231de6c804136833c1d988e82057c3d94494
d9cc908ab460e649c88c405389f930411cdad00410d8518e5b784018d6d0c737
c2b18d2820001849195d3b5d4315760634600af921524aa74f8a902b9597fce7
0d416715f4f13000ebf8061400100152a4631e2118408fb6008477b8431fd808
01006880c6413d336def18943277d6bc78b875a474adeb843e43b55de5f11de8
30c73fd8e10e6e7aa01de740c21adec18e76d409029ee054fb7cca4e4dfef1e4
870c106a4037f5ce79ea09884b340dd7365695d3bc3287952d6aea56891a7394
810df0b8c402a0910e74482324a4b8c135f2180f2ea8e11d725b874e86591338
0aceadcd1b54beea8adc661e4d47e699e061e8818efadc63449110c000987048
7d3c8109f0c0061ebb354aa248659dfd3bd0409152d9a98e0ea97df2e954fa27
94aec997633eede750a69104536c031b6a80e12113948539bce51cf4408671ee
064d1a210a71c28d63721fac5c9c45d08e94b9cb3860120f74d08332f0300725
68600c785c4e1c458c9fe8a62215d3d6efbc258e27685f843a756e12754c5ae7
4e7ada542072aca80a99c6181ac10e6ab06206d660073a9c31820818fea31ef7
e8c64c0e12199a4d983104236ea284fb46086b79cb0ee18400607118064f642b
e7c887000ae0934721b6012292063b0e108eb808072602986004f9c128af4e15
00033892ece499b594dc6a4447590711ddebde89154048ad8b8701ea711e01dc
c31e8da1ccdd0e609b70cc27000e200046a64188299cb01b2cf0c53be6e10442
cc491fece5b2ab5fdd9194702276c010b344f4b6107ad00300041800035e39a2
7a0c342100b0174f32d5a1347a03293a92c70162f525d901c027f3e2d09738e3
13d774ab5b73594f555212806786fb1dd1a8b340f2112b0e256728b68e0835b4
b1024f7403171830356c0eb20f52c17adffc560ad28e451148cb26fe3e548080
3060c2c32f693100ea3840a1d0b7206fdf9047c7e389a202b0e000b4710002c1
4f00a676b185781bbe13bf614ab0c58f6c60ec1dc5562b00ea61000928fc4bf0
084213122aa28ccc631d9b10805454fd0e10292b1ec3eab7d18f3e11790c2bcc
18d18740448c0e190c62d6a4603238e2d18b6d44860279ee114f1015242c2567
2e6b8a6f64f481f14cfd64652212fb3be4d1986d4c7292e7439f3ad6d1704813
473cd09a0a72de310637c8840f5f62441effa18f701c9322b631ae490ea3a378
a863f148af7ce53dc4f48ba0831d247ec6249ec00e7bfc810ee27807190a1003
0eb8411f5eb06ed5df2173eb0ee0d9e85b1601f801f7f1458601fefcf0c6a268
95b2776c03d3a441d28dab329475ca8327277f87c2af22f1e398631d3120856d
52228640248454ed86c89c28bd8d0eaa2453725dc7b22d8ffea3bb66203fa308
38384f8f6770c111e230471ede608d4310011d720b0d3a7271031c0007311141
61d21357216d2ee6750c102454851002a024ce070ef9500f03200d03c1133e15
4fd4c62828a31265f346f53110d7e00c983003a52717ef10086ab033598211df
b70f50f6403a337994977e37e86a44d37d0f810c79040ecd6004a6606469f008
d600043ba00002c62f74b204a0010ff6622c2681141b020f70c700e4b321eab0
28e9062d06700009000032d70009300012c021070082e42549fe4121108aa221
02110d25002637f039fff00c60000773331def800942400fb3912d3be810d211
0fd780105a988204a32138c8885a263844c41193530ff1700c2ab064eb7004b8
200e2c7009d980068321108c2078e37733840252002227fcb00f94c668be651c
ddf687a79279ad8610edb0510871086b302263000954d30c85441b48510b3cc0
0d7733272d5811e7714c701727b064838d088dcdf48c19a11c26710c47d009f5
e00b23400db8f003bf300edd10086e201063700877863873a14670a58c47d10a
1af00007800a933809b2c7088075040f00000b408eec57112b3123b9e8219c90
0402510b464035b34235e0300236a004f5201a1a11570b61fe1bc76591d18891
379812b4910d7d60009d3608f3300f31f00bfc600ee6f80fe140052b02130926
1e1ea510fb302802045de8600489000ea53003d5500b1f300cefe00a24800a46
960a3ab048b30811bcd256ce310875f016bc408cf530086b300eb6014cebf00c
47c001c4500ff6000e82e810c57523719246196996e9070f12b20e9e710fd3a5
2383a00002d00033100cf4700b12e0096b41806eb478cc8329f0800ed4d00d46
a00cd8500f4dc00993400530210d5fb008e2800eaca003c480941041291c750f
b1610937400eff200d30500ce260049c100f6230006f3089e8e005a5c00ed530
412c421120752370846567699b22259bb12913e1901b0afeb561fb610fe82024
6c610f94605d7080617cd38637a346f01012f3300dd40004be20244b8009c880
04aaf00edaa003d5600df320995313663b283329b120d22003d7f00eb06004d7
e00e19f025e47878ba86472d7317173110c4151973559bb7e99f729433d3f810
dc422899b237ce090f6862887012416985333ac39c8283a0e8109dd329174f60
09e3a00b5ca70097500ff5770b3a900c95f9106db833f5d20732c00d4b500704
619e227835a301411811a1fb0952b9f99f395a38012aa00e114130710d58c20d
74930f96211d07c22f2e599b351a8307610f5e41985fc9049b200d2e500effa0
0d2c600ce7d00da90004b9237c00a72ff9393cc1150fe17b0000904033097235
c3a31b94a62047241170954c8283a33a8aa741c3a3187152349336e44781ff90
1b07629e6bc510664a9b2a9329f6600f544008cd500a4a500de1600299f00ebe
c002c1b055b1b001165007991711b4d232f63222c3b21c545313ed7077792314
34c15c1d61a771d4a3794aabc0b2a7f8e95c083623f9b9516c110fde65326cf1
841509930c611b723241b2200115e00042080ea920000b10019b7013f6f00a40
209e62ea1021e21c2ab16c3ffa846fe20d851a196e7a9f16d1827112ab765aab
edeaaeef0aaff12aaff34aaff56aaff78aaff9aaaffd1210003b
