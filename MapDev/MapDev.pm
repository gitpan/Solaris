package Solaris::MapDev;
use strict;
use Exporter;
use IO::File;
use Symbol;   # Would like to use IO::Dir, but that isn't available in 5.004_04
use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS);
$VERSION = '0.03';
@ISA = qw(Exporter);
@EXPORT_OK = qw(inst_to_dev dev_to_inst get_inst_names get_dev_names);
%EXPORT_TAGS = ( ALL => [ @EXPORT_OK ] );

# Maps of instance to /dev name and vice versa
use vars qw($inst_to_dev $dev_to_inst);

################################################################################
# Private routine to rebuild the inst_to_dev lookup table.  This is called the
# first time either dev_to_inst or inst_to_dev is called, and also if a device
# cannot be found in the lookup hashes.  It rebuilds $inst_to_dev only, on the
# assumption that we will rarely want to map back from a device to the instance.
# $dev_to_inst is rebuilt when required by dev_to_inst

sub _refresh()
{
$inst_to_dev = {};
$dev_to_inst = {};

# Read /etc/path_to_inst, and build a map from disk and tape /devices entries
# to instance names
my ($fh, $dh, $dir, $line, $dev, $inst, $lnk, %device_to_inst);
$fh = IO::File->new("/etc/path_to_inst", "r") || die;
$dh = gensym;
while (defined($line = $fh->getline()))
   {
   next if ($line =~ /^\s*#/);
   $line =~ s/"//g;
   my $drv;
   ($dev, $inst, $drv) = split(' ', $line);
   if ($drv =~ /^(ss?d|st)$/)
      {
      $device_to_inst{"/devices$dev"} = "$drv$inst";
      }
   elsif ($drv eq "fd")
      {
      $inst_to_dev->{"$drv$inst"} = "$drv$inst";
      }
   elsif ($drv eq "cmdk")
      {
      $device_to_inst{"/devices$dev"} = "sd$inst";
      }
   elsif ($drv eq "dad")
      {
      $device_to_inst{"/devices$dev"} = "dad$inst";
      }
   elsif ($drv eq "atapicd")
      {
      $device_to_inst{"/devices$dev"} = "atapicd$inst";
      }
   }
$fh->close();

# Next find all the disk nodes under /dev and /dev/osa if it exists.
# /dev/osa contains extra device nodes not found under /dev for the Symbios
# HW RAID controllers (A1000, A3000).  Note however that if the devices are
# removed, the old info in /dev/osa is not removed, and if any more
# non-Symbios disks are added it will become incorrect.  To get around this, we
# read /dev/osa first if it exists, then /dev.  This will make sure that we get
# the most up-to-date information.
foreach $dir ('/dev/osa/rdsk', '/dev/osa/dev/rdsk', '/dev/rdsk')
   {
   next if (! -d $dir);
   opendir($dh, $dir) || die("Cannot read $dir: $!\n");
   while (defined($dev = readdir($dh)))
      {
      next if ($dev !~ /s0$/);
      $lnk = readlink("$dir/$dev");
      $lnk =~ s/^\.\.\/\.\.//;
      $lnk =~ s/:.*$//;
      if (defined($device_to_inst{$lnk}))
         {
         $dev =~ s/s0$//;
         $inst_to_dev->{$device_to_inst{$lnk}} = $dev;
         }
      }
   closedir($dh);
   }

# Now we do the same for all the tape devices under /dev/rmt
$dir = '/dev/rmt';
opendir($dh, $dir) || die("Cannot read $dir: $!\n");
while (defined($dev = readdir($dh)))
   {
   next if ($dev !~ /^\d+$/);
   $lnk = readlink("$dir/$dev");
   $lnk =~ s/^\.\.\/\.\.//;
   $lnk =~ s/:.*$//;
   if (defined($device_to_inst{$lnk}))
      {
      $inst_to_dev->{$device_to_inst{"$lnk"}} = "rmt/$dev";
      }
   }
closedir($dh);

# Now read in /etc/mnttab and add entries for nfs mount points
$fh = IO::File->new("/etc/mnttab", "r") || die;
while (defined($line = $fh->getline()))
   {
   next if ($line =~ /^\s*#/);
   my ($special, $fstyp, $opt) = (split(' ', $line))[0,2,3];
   next if ($fstyp ne "nfs");
   $opt =~ s/.*dev=(\w+).*/hex($1) & 0x3ffff/e;
   $inst_to_dev->{"nfs$opt"} = $special;
   }
$fh->close();
}

################################################################################
# Map an instance name to a device name, rebuilding $inst_to_dev as required

sub inst_to_dev($)
{
my ($inst) = @_;
my ($i, $s);
# Special treatment for disks with slice info
if ($inst =~ /^(ss?d\d+)(?:,(\w))$/ || $inst =~ /^(dad)(?:,(\w))$/)
   {
   $i = $1;
   $s = "s" . (ord($2) - ord('a'));
   }
else
   {
   $i = $inst;
   $s = "";
   }
_refresh() if (! exists($inst_to_dev->{$i}));
if (exists($inst_to_dev->{$i})) { return("$inst_to_dev->{$i}$s"); }
else { return(undef); }
}

################################################################################
# Map a device name to an instance name, rebuilding $dev_to_inst as required

sub dev_to_inst($)
{
my ($dev) = @_;
my ($d, $s);
# Special treatment for disks with slice info
if ($dev =~ /^(c\d+t\d+d\d+)(?:s(\d))$/)
   {
   $d = $1;
   $s = "," . chr(ord('a') + $2);
   }
else
   {
   $d = $dev;
   $s = "";
   }
if (! defined($inst_to_dev) || ! exists($dev_to_inst->{$d}))
   {
   _refresh();
   %$dev_to_inst = reverse(%$inst_to_dev);
   }
if (exists($dev_to_inst->{$d})) { return("$dev_to_inst->{$d}$s"); }
else { return(undef); }
}

################################################################################
# Get a list of all the instance names

sub get_inst_names()
{
_refresh() if (! defined($inst_to_dev));
return(sort(keys(%$inst_to_dev)));
}

################################################################################
# Get a list of all the device names

sub get_dev_names()
{
_refresh() if (! defined($inst_to_dev));
return(sort(values(%$inst_to_dev)));
}

################################################################################
1;
__END__

=head1 NAME

Solaris::MapDev - map between instance numbers and device names

=head1 SYNOPSIS

   use Solaris::MapDev qw(inst_to_dev dev_to_inst inst_dev_display);
   my $disk = inst_to_dev("sd0");
   my $tape = inst_to_dev("st1");
   my $nfs = inst_to_dev("nfs123");
   my $inst = dev_to_inst("c0t0d0s0");

=head1 DESCRIPTION

This module maps both ways between device instance names (e.g. sd0) and /dev
entries (e.g. c0t0d0).  'Vanilla' SCSI disks, SSA disks, A1000, A3000, A3500
and A5000 disks are all catered for, as are tape devices and NFS mounts.

=head1 FUNCTIONS

=head2 inst_to_dev($inst)

Return the device name name given the instance name

=head2 dev_to_inst($dev)

Return the instance name given the device name

=head2 get_inst_names

Return a sorted list of all the instance names

=head2 get_dev_names

Return a sorted list of all the device names

=head1 AUTHOR

Alan Burlison, <Alan.Burlison@uk.sun.com>

=head1 SEE ALSO

L<perl(1)>, F</etc/path_to_inst>, F</dev/osa>, F</dev/rdsk>, F</dev/rmt>,
F</etc/mnttab>

=cut
