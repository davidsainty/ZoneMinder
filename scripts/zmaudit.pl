#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Audit Script, $Date$, $Revision$
# Copyright (C) 2003, 2004, 2005  Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================
#
# This script checks for consistency between the event filesystem and
# the database. If events are found in one and not the other they are
# deleted (optionally). Additionally any monitor event directories that
# do not correspond to a database monitor are similarly disposed of.
# However monitors in the database that don't have a directory are left
# alone as this is valid if they are newly created and have no events
# yet.
#
use strict;
use bytes;

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================

use constant MIN_AGE => 300; # Minimum age when we will delete anything
use constant RECOVER_TAG => "(r)"; # Tag to append to event name when recovered
use constant RECOVER_TEXT => "Recovered."; # Text to append to event notes when recovered

use constant DBG_LEVEL => 1; # 0 is errors, warnings and info only, > 0 for debug

# ==========================================================================
#
# You shouldn't need to change anything from here downwards
#
# ==========================================================================

use ZoneMinder;
use DBI;
use POSIX;
use Time::HiRes qw/gettimeofday/;
use Getopt::Long;

use constant LOG_FILE => ZM_PATH_LOGS.'/zmaudit.log';
use constant IMAGE_PATH => ZM_PATH_WEB.'/'.ZM_DIR_IMAGES;
use constant EVENT_PATH => ZM_PATH_WEB.'/'.ZM_DIR_EVENTS;

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $report = 0;
my $yes = 0;
my $delay = 0;

sub usage
{
	print( "
Usage: zmaudit.pl [-r,-report|-y,-yes] [-d <seconds>,-delay=<seconds>]
Parameters are :-
-r, --report                    - Just report don't actually do anything
-y, --yes                       - Just do all actions without confirmation
-d <seconds>, --delay=<seconds> - how long to delay between each pass, the default of 0 means run once only.
");
	exit( -1 );
}

my $dbg_id = "";

sub dbgInit
{
	my $id = shift;
	if ( $id )
	{
		$dbg_id = $id;
		my $add_parms = shift;
		if ( $add_parms )
		{
			foreach my $arg ( @ARGV )
			{
				if ( $arg =~ /^-(.*)$/ )
				{
					$dbg_id .= "_$1";
				}
				else
				{
					$dbg_id .= $arg;
				}
			}
		}
	}
}

sub dbgPrint
{
	my $code = shift;
	my $string = shift;
	my $line = shift;

	$string =~ s/[\r\n]+$//g;

	my ($seconds, $microseconds) = gettimeofday();
	if ( $line )
	{
		my $file = __FILE__;
		$file =~ s|^.*/||g;
		printf( "%s.%06d %s[%d].%s-%s/%d [%s]\n", strftime( "%x %H:%M:%S", localtime( $seconds ) ), $microseconds, $dbg_id, $$, $file, $line, $code, $string );
	}
	else
	{
		printf( "%s.%06d %s[%d].%s [%s]\n", strftime( "%x %H:%M:%S", localtime( $seconds ) ), $microseconds, $dbg_id, $$, $code, $string );
	}
}

sub Debug
{
	dbgPrint( "DBG", $_[0] ) if ( DBG_LEVEL >= 1 );
}

sub Info
{
	dbgPrint( "INF", $_[0] ) if ( DBG_LEVEL >= 0 );
}

sub Warning
{
	dbgPrint( "WAR", $_[0] ) if ( DBG_LEVEL >= -1 );
}

sub Error
{
	dbgPrint( "ERR", $_[0] ) if ( DBG_LEVEL >= -2 );
}

sub aud_print
{
	my $string = shift;
	if ( $delay )
	{
		Info( $string );
	}
	else
	{
		print( $string );
	}
}

sub confirm
{
	my $prompt = shift || "delete";
	my $action = shift || "deleting";

	my $yesno = $yes?1:0; 
	if ( $report )
	{
		if ( !$delay )
		{
			print( "\n" );
		}
	}
	elsif ( $yes )
	{
		if ( $delay )
		{
			Info( "$action\n" );
		}
		else
		{
			print( ", $action\n" );
		}
	}
	else
	{
		print( ", $prompt y/n: " );
		my $char = <>;
		chomp( $char );
		if ( $char eq 'q' )
		{
			exit( 0 );
		}
		if ( !$char )
		{
			$char = 'y';
		}
		if ( $char eq "a" )
		{
			$yes = 1;
			return( 1 );
		}
		$yesno = ( $char =~ /[yY]/ );
	}
	return( $yesno );
}

dbgInit( "zmaudit", 1 );

if ( !GetOptions( 'report'=>\$report, 'yes'=>\$yes, 'delay=i'=>\$delay ) )
{
	usage();
}

if ( $report && $yes )
{
	print( STDERR "Error, only one of --report and --yes may be specified\n" );
	usage();
}

my $dbh = DBI->connect( "DBI:mysql:database=".ZM_DB_NAME.";host=".ZM_DB_HOST, ZM_DB_USER, ZM_DB_PASS );

chdir( EVENT_PATH );
if ( $delay ) # Background mode
{
	open( LOG, ">>".LOG_FILE ) or die( "Can't open log file: $!" );
	open( STDOUT, ">&LOG" ) || die( "Can't dup stdout: $!" );
	select( STDOUT ); $| = 1;
	open( STDERR, ">&LOG" ) || die( "Can't dup stderr: $!" );
	select( STDERR ); $| = 1;
	select( LOG ); $| = 1;
}
my $max_image_age = 15/(24*60); # 15 Minutes
my $image_path = IMAGE_PATH;
do
{
	my $db_monitors;
	my $sql1 = "select Id from Monitors order by Id";
	my $sth1 = $dbh->prepare_cached( $sql1 ) or die( "Can't prepare '$sql1': ".$dbh->errstr() );
	my $sql2 = "select Id, (unix_timestamp() - unix_timestamp(StartTime)) as Age from Events where MonitorId = ? order by Id";
	my $sth2 = $dbh->prepare_cached( $sql2 ) or die( "Can't prepare '$sql2': ".$dbh->errstr() );
	my $res = $sth1->execute() or die( "Can't execute: ".$sth1->errstr() );
	while( my $monitor = $sth1->fetchrow_hashref() )
	{
		Debug( "Found database monitor '$monitor->{Id}'" );
		my $db_events = $db_monitors->{$monitor->{Id}} = {};
		my $res = $sth2->execute( $monitor->{Id} ) or die( "Can't execute: ".$sth2->errstr() );
		while ( my $event = $sth2->fetchrow_hashref() )
		{
			$db_events->{$event->{Id}} = $event->{Age};
		}
		Debug( "Got ".int(keys(%$db_events))." events\n" );
		$sth2->finish();
	}
	$sth1->finish();

	my $fs_now = time();
	my $fs_monitors;
	foreach my $monitor ( <[0-9]*> )
	{
		Debug( "Found filesystem monitor '$monitor'" );
		my $fs_events = $fs_monitors->{$monitor} = {};
		( my $monitor_dir ) = ( $monitor =~ /^(.*)$/ ); # De-taint

		opendir( DIR, $monitor_dir ) or die( "Can't open directory '$monitor_dir': $!" );
		my @temp_events = sort { $b <=> $a } grep { $_ =~ /^\d+$/ } readdir( DIR );
		closedir( DIR );
		chdir( $monitor_dir );
		my $count = 0;
		foreach my $event ( @temp_events )
		{
			if ( $count++ > 25 )
			{
				$fs_events->{$event} = -1;
			}
			else
			{
				$fs_events->{$event} = ($fs_now - ($^T - ((-M $event) * 24*60*60)));
			}
		}
		chdir( EVENT_PATH );
		Debug( "Got ".int(keys(%$fs_events))." events\n" );
	}

	while ( my ( $fs_monitor, $fs_events ) = each(%$fs_monitors) )
	{
		if ( my $db_events = $db_monitors->{$fs_monitor} )
		{
			if ( $fs_events )
			{
				while ( my ( $fs_event, $age ) = each(%$fs_events ) )
				{
					if ( !defined($db_events->{$fs_event}) && ($age < 0 || ($age > MIN_AGE)) )
					{
						aud_print( "Filesystem event '$fs_monitor/$fs_event' does not exist in database" );
						if ( confirm() )
						{
							my $command = "/bin/rm -rf ".EVENT_PATH."/$fs_monitor/$fs_event";
							qx( $command );
						}
					}
				}
			}
		}
		else
		{
			aud_print( "Filesystem monitor '$fs_monitor' does not exist in database" );
			if ( confirm() )
			{
				my $command = "rm -rf ".EVENT_PATH."/$fs_monitor";
				qx( $command );
			}
		}
	}

	my $sql3 = "delete from Monitors where Id = ?";
	my $sth3 = $dbh->prepare_cached( $sql3 ) or die( "Can't prepare '$sql3': ".$dbh->errstr() );
	my $sql4 = "delete from Events where Id = ?";
	my $sth4 = $dbh->prepare_cached( $sql4 ) or die( "Can't prepare '$sql4': ".$dbh->errstr() );
	my $sql5 = "delete from Frames where EventId = ?";
	my $sth5 = $dbh->prepare_cached( $sql5 ) or die( "Can't prepare '$sql5': ".$dbh->errstr() );
	my $sql6 = "delete from Stats where EventId = ?";
	my $sth6 = $dbh->prepare_cached( $sql6 ) or die( "Can't prepare '$sql6': ".$dbh->errstr() );
	while ( my ( $db_monitor, $db_events ) = each(%$db_monitors) )
	{
		if ( my $fs_events = $fs_monitors->{$db_monitor} )
		{
			if ( $db_events )
			{
				while ( my ( $db_event, $age ) = each(%$db_events ) )
				{
					if ( !defined($fs_events->{$db_event}) && ($age > MIN_AGE) )
					{
						aud_print( "Database event '$db_monitor/$db_event' does not exist in filesystem" );
						if ( confirm() )
						{
							my $res = $sth4->execute( $db_event ) or die( "Can't execute: ".$sth4->errstr() );
							$res = $sth5->execute( $db_event ) or die( "Can't execute: ".$sth5->errstr() );
							$res = $sth6->execute( $db_event ) or die( "Can't execute: ".$sth6->errstr() );
						}
					}
				}
			}
		}
		else
		{
			#aud_print( "Database monitor '$db_monitor' does not exist in filesystem" );
			#if ( confirm() )
			#{
				# We don't actually do this in case it's new
				#my $res = $sth3->execute( $db_monitor ) or die( "Can't execute: ".$sth3->errstr() );
			#}
		}
	}

	my $sql7 = "select distinct EventId from Frames left join Events on Frames.EventId = Events.Id where isnull(Events.Id) group by EventId";
	my $sth7 = $dbh->prepare_cached( $sql7 ) or die( "Can't prepare '$sql7': ".$dbh->errstr() );
	$res = $sth7->execute() or die( "Can't execute: ".$sth7->errstr() );
	while( my $frame = $sth7->fetchrow_hashref() )
	{
		aud_print( "Found orphaned frame records for event '$frame->{EventId}'" );
		if ( confirm() )
		{
			$res = $sth5->execute( $frame->{EventId} ) or die( "Can't execute: ".$sth6->errstr() );
		}
	}

	my $sql8 = "select distinct EventId from Stats left join Events on Stats.EventId = Events.Id where isnull(Events.Id) group by EventId";
	my $sth8 = $dbh->prepare_cached( $sql8 ) or die( "Can't prepare '$sql8': ".$dbh->errstr() );
	$res = $sth8->execute() or die( "Can't execute: ".$sth8->errstr() );
	while( my $stat = $sth8->fetchrow_hashref() )
	{
		aud_print( "Found orphaned statistic records for event '$stat->{EventId}'" );
		if ( confirm() )
		{
			$res = $sth6->execute( $stat->{EventId} ) or die( "Can't execute: ".$sth6->errstr() );
		}
	}

	# New audit to close any events that were left open for longer than MIN_AGE seconds
	my $sql9 = "select E.Id, max(F.TimeStamp) as EndTime, unix_timestamp(max(F.TimeStamp)) - unix_timestamp(E.StartTime) as Length, count(F.Id) as Frames, count(if(F.Score>0,1,NULL)) as AlarmFrames, sum(F.Score) as TotScore, max(F.Score) as MaxScore, M.EventPrefix as Prefix from Events as E left join Monitors as M on E.MonitorId = M.Id inner join Frames as F on E.Id = F.EventId where isnull(E.Frames) group by E.Id having EndTime < (now() - interval ".MIN_AGE." second)"; 
	my $sth9 = $dbh->prepare_cached( $sql9 ) or die( "Can't prepare '$sql9': ".$dbh->errstr() );
	my $sql10 = "update Events set Name = ?, EndTime = ?, Length = ?, Frames = ?, AlarmFrames = ?, TotScore = ?, AvgScore = ?, MaxScore = ?, Notes = concat_ws( ' ', Notes, ? ) where Id = ?";
	my $sth10 = $dbh->prepare_cached( $sql10 ) or die( "Can't prepare '$sql10': ".$dbh->errstr() );
	$res = $sth9->execute() or die( "Can't execute: ".$sth9->errstr() );
	while( my $event = $sth9->fetchrow_hashref() )
	{
		aud_print( "Found open event '$event->{Id}'" );
		if ( confirm( 'close', 'closing' ) )
		{
			$res = $sth10->execute( sprintf( "%s%d%s", $event->{Prefix}, $event->{Id}, RECOVER_TAG ), $event->{EndTime}, $event->{Length}, $event->{Frames}, $event->{AlarmFrames}, $event->{TotScore}, $event->{AlarmFrames}?int($event->{TotScore}/$event->{AlarmFrames}):0, $event->{MaxScore}, RECOVER_TEXT, $event->{Id} ) or die( "Can't execute: ".$sth10->errstr() );
		}
	}

	# Now delete any old image files
	if ( my @old_files = grep { -M > $max_image_age } <$image_path/*.{jpg,gif,wbmp}> )
	{
		aud_print( "Deleting ".int(@old_files)." old images\n" );
		my $untainted_old_files = join( ";", @old_files );
		( $untainted_old_files ) = ( $untainted_old_files =~ /^(.*)$/ );
		unlink( split( ";", $untainted_old_files ) );
	}

	sleep( $delay ) if ( $delay );
} while( $delay );