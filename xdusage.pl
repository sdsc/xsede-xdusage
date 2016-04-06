#!/usr/bin/env perl
use strict;
use Getopt::Long;
use Date::Manip;

use LWP::UserAgent;
use JSON;
use URI::Escape;
use Data::Dumper;

Getopt::Long::Configure ("no_ignore_case");

# find out where this script is running from
# eliminate the need to configure an install dir
use FindBin qw($RealBin);
my($install_dir) = $RealBin;

# load the various settings from a configuration file
# (api_id, api_key, rest_url_base, resource_name, admin_name)
# file is simple key=value, ignore lines that start with #

my($APIKEY);
my($APIID);
my($resource);
my(@admin_names);
my($conf_file);
my($rest_url);

# list of possible config file locations
my(@conf_file_list) = ('/etc/xdusage.conf', 
	      '/var/secrets/xdusage.conf', 
	      "$install_dir/xdusage.conf",
	      ) ;

# use the first one found.
foreach my $c (@conf_file_list)
{
    if (-r $c)
    {
        $conf_file = $c;
        last;
    }
}

die "Unable to find xdusage.conf in:\n  " . join("\n  ", @conf_file_list) . 
    "\n" unless ($conf_file);

# read in config file
open FD, "<$conf_file" or die "$!: $conf_file";
while(<FD>)
{
    chomp;
    next if ( /^\s*#/ );
    next if ( /^\s*$/ );
    if( ! /^([^=]+)=([^=]+)$/ )
    {
        print stderr "Ignoring cruft in $conf_file: '$_'\n";
	next;
    }
    my $key = $1;
    my $val = $2;
    $key =~ s/^\s*//g;
    $key =~ s/\s*$//g;
    $val =~ s/^\s*//g;
    $val =~ s/\s*$//g;

    if ($key eq 'api_key')
    {
        die "Multiple 'api_key' values in $conf_file" if ($APIKEY);
	$APIKEY = $val;
    }
    elsif ($key eq 'api_id')
    {
        die "Multiple 'api_id' values in $conf_file" if ($APIID);
	$APIID = $val;
    }
    elsif ($key eq 'resource_name')
    {
        die "Multiple 'resource_name' values in $conf_file" if ($resource);
	$resource = $val;
    }
    elsif ($key eq 'admin_name')
    {
        unshift(@admin_names,$val);
    }
    elsif ($key eq 'rest_url_base')
    {
	die "Multiple 'rest_url_base' values in $conf_file" if ($rest_url);
	$rest_url = $val;
    }
    else
    {
        print stderr "Ignoring cruft in $conf_file: '$_'\n";
    }
}
close FD or die "$!: $conf_file";

# stop here if missing required values
die "Unable to find 'api_key' value in $conf_file" unless ($APIKEY);
die "Unable to find 'resource_name' value in $conf_file" unless ($resource);
die "Unable to fine 'rest_url_base' value in $conf_file" unless ($rest_url);


my($me) = (split /\//, $0)[-1];
my($logname)     = $ENV{SUDO_USER}           || die "SUDO_USER not set\n";

my(%options) = ();
usage() unless 
 GetOptions (\%options,
            "p=s@",
            "r=s@",
            "u=s@",
            "up=s@",
            "s=s",
            "e=s",
            "a",
            "j",
            "ja",
            "pa",
            "ia",
            "ip",
	    "zp",
	    "za",
	    "nc",
            "h",
	    "debug",
	    "V",
            ) ;

usage() if (@ARGV);
usage() if option_flag('h');
version() if option_flag('V');

my($DEBUG) = option_flag('debug');
my($today) = UnixDate(ParseDate('today'),  "%Y-%m-%d");
my($is_admin) = is_admin($logname);
my($xuser) = ($is_admin && $ENV{USER}) ? $ENV{USER} : $logname;


my($user)     = get_user($xuser);
my(@resources) = get_resources();

my(@users)     = get_users();
my(@plist)     = option_list('p');
my($sdate, $edate, $edate2) = get_dates();
my(@projects) = get_projects();
my($project);
my($any) = 0;
foreach $project (@projects)
{
    $any = 1 if show_project($project);
}
error ("No projects and/or accounts found") unless ($any);

exit(0);


# perform a request to a URL that returns JSON
# returns JSON if successful
# dies if there's an error, printing diagnostic information to
# stderr.
# error is:  non-200 result code, or result is not JSON.
sub json_get($)
{
    my($url) = shift;

    # using LWP since it's available by default in most cases
    my $ua = LWP::UserAgent->new();
    $ua->default_header('XA-AGENT' => 'xdusage');
    $ua->default_header('XA-RESOURCE' => $APIID);
    $ua->default_header('XA-API-KEY' => $APIKEY);
    my $resp = $ua->get($url);

    # check for bad response code here
    if (!defined $resp || $resp->code != 200)
    {
	die(sprintf("Failure: %s returned erroneous status: %s", $url, $resp->status_line));
    }

    # do stuff with the body
    my $json = decode_json($resp->content);

    # not json? this is fatal too.
    if (!defined $json)
    {
	die(sprintf("Failure: %s returned non-JSON output: %s\n", $url, $resp->content));
    }

    # every response must contain a 'result' field.
    if (!defined $json->{'result'})
    {
	die(sprintf("Failure: %s returned invalid JSON (missing result): %s\n", $url, $resp->content));
    }

    return $json;
}

sub is_admin()
{
    my($user) = shift;
    my($is_admin) = 0;

    foreach (@admin_names)
    {
	$is_admin = 1 if ($user eq $_);
    }
    $is_admin;
}

# returns a list of hashref of user info for a given username at a given resource
# resource defaults to config param resource_name; if second arg evaluates 
# to true, use the portal as the resource.
sub get_user
{
    my($username, $portal) = @_;
    my($rs) = $portal ? 'portal.teragrid' : $resource;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/people/by_username/%s/%s", 
      $rest_url, 
      uri_escape($rs), 
      uri_escape($username));
    my $result = json_get($url);

    # there should be only one row returned here...
    if (scalar @{$result->{result}} > 1)
    {
	die(sprintf("Multiple user records for user %s on resource %s\n", 
	  $username, $rs));
    }

    return @{$result->{result}};
}

# returns a list of hashrefs of user info for all users with the
# given last name.
sub get_users_by_last_name
{
    my($name) = shift;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/people/by_lastname/%s", 
      $rest_url, 
      uri_escape($name));
    my $result = json_get($url);

    # conveniently, the result is already in the form the caller expects.
    return @{$result->{result}};
}

# returns a list of hashrefs of user info for every user
# described by the -u and -up arguments.
sub get_users
{
    my(@users) = ();
    my($name);
    my(@u);

    foreach $name (option_list('u'))
    {
	@u = (get_user($name), get_users_by_last_name($name));
	error("user $name not found") unless (@u);
        push @users, @u;
    }

    foreach $name (option_list('up'))
    {
        @u = get_user ($name, 1);
	error("user $name not found") unless (@u);
        push @users, @u;
    }

    @users;
}

# return a list of resource IDs (numeric) described by -r arguments.
sub get_resources
{
    my(@resources) = ();
    my($name, $r);
    my($pat);
    my($any);
    my($url);

    foreach $name (option_list('r'))
    {
	# since nobody remembers the full name, do a search based on
	# the subcomponents provided
	$pat = $name;
	$pat = "$name.%" unless ($name =~ /[.%]/);

	# create a rest url and fetch
	$url = sprintf("%s/xdusage/v1/resources/%s",
	  $rest_url,
	  uri_escape($pat));
	my $result = json_get($url);

	$any = 0;
	foreach $r (@{$result->{result}})
	{
	    push @resources, $r->{resource_id};
	    $any = 1;
	}
	error ("$name - resource not found") unless ($any);
    }

    @resources;
}

# return a list of hashrefs of project info described by
# -p (project list), -ip (filter active) args
# restricted to non-expired projects associated with
# current user by default
sub get_projects
{
    return unless ($user);

    my($person_id) = $user->{person_id};
    my($is_su)     = $user->{is_su};

    my(@urlparams);

    # filter by project list?
    # (grant number, charge number)
    if (scalar @plist)
    {
	unshift(@urlparams, sprintf("projects=%s",
	  uri_escape(lc(join(',', @plist)))));
    }
    # If not filtering by project list, show all non-expired
    else
    {
	unshift(@urlparams, "not_expired");
    }

    # non-su users are filtered by person_id 
    # so they can't see someone else's project info
    if (!$is_su)
    {
	unshift(@urlparams, sprintf("person_id=%s", 
	  uri_escape($person_id)));
    }

    # filter by active
    if (option_flag('ip'))
    {
	unshift(@urlparams, "active_only");
    }

    # filter by resources
    if (scalar @resources)
    {
	unshift(@urlparams, sprintf("resources=%s",
	    uri_escape(join(',',@resources))));
    }

    # construct a rest url and fetch it
    # input has already been escaped
    my $url = sprintf("%s/xdusage/v1/projects?%s", 
      $rest_url, 
      join('&', @urlparams));
    my $result = json_get($url);

    # return an empty array if no results
    if (scalar @{$result->{result}} < 1)
    {
	return ();
    }

    return  @{$result->{result}};
}

# return curent allocation info for account_id on resource_id
# returns previous allocation info if 3rd argument evaluates to true.
sub get_allocation
{
    my($account_id, $resource_id, $previous) = @_;

    my($prevstr) = "current";
    if ($previous)
    {
	$prevstr = "previous";
    }

    # construct a rest url and fetch it
    # don't forget to escape input...
    my $url = sprintf("%s/xdusage/v1/allocations/%s/%s/%s", 
      $rest_url, 
      uri_escape($account_id),
      uri_escape($resource_id),
      uri_escape($prevstr));
    my $result = json_get($url);

    # the caller checks for undef, so we're good to go.
    # note that the result is NOT an array this time.
    return $result->{result};
}

# return list of hashref of account info on a given project
# optionally filtered by username list and active-only
sub get_accounts
{
    my($project) = shift;
    my($person_id) = $user->{person_id};
    my($is_su)     = $user->{is_su};

    my(@urlparams);

    # filter by personid(s)
    if (@users || !(option_flag('a') || $is_su))
    {
	if (scalar @users)
	{
	    unshift(@urlparams, sprintf("person_id=%s",
	      uri_escape(join(',', map {$_->{person_id}} @users))));
	}
	else
	{
	    unshift(@urlparams, sprintf("person_id=%s",
	      uri_escape($person_id)));
	}
    }
	 
    # filter by active accounts
    if (option_flag('ia'))
    {
	unshift(@urlparams, "active_only");
    }

    # construct a rest url and fetch it
    # input has already been escaped
    my $url = sprintf("%s/xdusage/v1/accounts/%s/%s?%s", 
      $rest_url,
      $project->{account_id},
      $project->{resource_id},
      join('&', @urlparams));
    my $result = json_get($url);

    # caller checks for undef
    return @{$result->{result}};
}

sub option_list
{
    my($opt) = shift;
    my(@list) = ();
    my($x) = $options{$opt};
    @list = split(/,/,join(',',@$x)) if ($x);
    @list;
}

sub option_flag
{
    my($opt) = shift;
    my($x) = $options{$opt};
    $x || 0;
}

sub usage
{
    print STDERR "Usage: $me [OPTIONS]\n\n";
    print STDERR "   OPTIONS\n";
    print STDERR "     -p  <project>\n";
    print STDERR "     -r  <resource>\n";
    print STDERR "     -u  <username|Last name>\n";
    print STDERR "     -up <portal-username>\n";
    print STDERR "     -a  (show all accounts -- ignored with -u)\n";
    print STDERR "     -j  (show jobs, refunds, etc)\n";
    print STDERR "     -ja (show additional job attributes -- ignored unless -j is specified)\n";
    print STDERR "     -pa (show previous allocation -- ignored with -s or -e)\n";
    print STDERR "     -ip (suppress inactive projects)\n";
    print STDERR "     -ia (suppress inactive accounts)\n";
    print STDERR "     -zp (suppress projects with zero usage)\n";
    print STDERR "     -za (suppress accounts with zero usage)\n";
    print STDERR "     -nc (don't use commas in reported amounts)\n";
    print STDERR "     \n";
    print STDERR "     -s  <start-date>\n";
    print STDERR "     -e  <end-date> (requires -s as well)\n";
    print STDERR "         (display usage for period between start-date and end-date)\n";
    print STDERR "     \n";
    print STDERR "     -V  (print version information)\n";
    print STDERR "     -h  (print usage message)\n";
    exit(1);
}

sub version
{
    print "xdusage version %VER%\n";
    exit(1);
}

sub show_project
{
    my($project) = shift;
    my(@a, $a, $w, $name);
    my($x, $amt, $alloc);
    my($s, $e);
    my($username);
    my(@j, @cd, $job_id, $id);
    my($ux, $any, $is_pi);
    my($sql, @jav, $jav);

    @a = get_accounts ($project);
    return 0 unless (@a);

    if ($sdate or $edate2)
    {
    	$x = get_usage_by_dates ($project->{account_id}, $project->{resource_id});
	$amt = $x->{su_used} || 0;
	return 0 if ($amt == 0 && option_flag('zp'));

	# $s = $x->{start_date} || $sdate;
	# $e = $x->{end_date} || $edate;
	$s = $sdate;
	$e = $edate;
	# $s = $sdate || $x->{start_date};
	# $e = $edate || $x->{end_date};

    	$x = get_counts_by_dates ($project->{account_id}, $project->{resource_id});
	$ux = sprintf "Usage Period: %s%s\n Usage=%s %s",
	       $s ? "$s/" : "thru ",
	       $e ? "$e" : $today,
	       fmt_amount($amt),
	       $x;
    }
    else
    {
    	$alloc = get_allocation ($project->{account_id}, $project->{resource_id}, option_flag('pa'));
	return 0 unless ($alloc);
	$amt = $alloc->{su_used};
	return 0 if ($amt == 0 && option_flag('zp'));

    	$x = get_counts_on_allocation ($alloc->{allocation_id});
	$ux = sprintf "Allocation: %s/%s\n Total=%s Remaining=%s Usage=%s %s",
	        $alloc->{alloc_start},
	        $alloc->{alloc_end},
	        fmt_amount($alloc->{su_allocated}), 
	        fmt_amount($alloc->{su_remaining}),
	        fmt_amount($amt),
	        $x;
    }

    $any = 0;
    foreach $a (@a)
    {
	$is_pi = $a->{is_pi};
	$w = $is_pi ? "PI" : "  ";
	$username = $a->{portal_username};
	$name = fmt_name ($a->{first_name}, $a->{middle_name}, $a->{last_name});

	if ($sdate or $edate2)
	{
	    $x = get_usage_by_dates ($project->{account_id}, $project->{resource_id}, $a->{person_id});
	    $amt = $x->{su_used};
	    $x = get_counts_by_dates ($project->{account_id}, $project->{resource_id}, $a->{person_id});
	    if (option_flag('j'))
	    {
		@j = get_jv_by_dates ($project->{account_id}, $project->{resource_id}, $a->{person_id});
		@cd = get_cdv_by_dates ($project->{account_id}, $project->{resource_id}, $a->{person_id});
	    }
	}
	else
	{
	    $amt = get_usage_on_allocation ($alloc->{allocation_id}, $a->{person_id});
	    $x = get_counts_on_allocation ($alloc->{allocation_id}, $a->{person_id});
	    if (option_flag('j'))
	    {
		@j = get_jv_on_allocation ($alloc->{allocation_id}, $a->{person_id});
		@cd = get_cdv_on_allocation ($alloc->{allocation_id}, $a->{person_id});
	    }
	}
	next if ($amt == 0 && option_flag('za'));
	unless ($any)
	{
	    print "Project: $project->{charge_number}";
	    print "/$project->{resource_name}";
	    print " status=inactive" unless ($project->{proj_state} eq 'active');
	    print "\n";
	    printf "PI: %s\n", fmt_name ($project->{pi_first_name}, $project->{pi_middle_name}, $project->{pi_last_name});
	    print "$ux\n";
	    $any = 1;
	}

	print " $w $name";
	print " portal=$username" if (defined $username);
	print " status=inactive" unless ($a->{acct_state} eq 'active');
	printf " usage=%s %s\n", fmt_amount ($amt || 0), $x;

	foreach $x (@j)
	{
	    print "      job";
	    $id = $x->{local_jobid};
	    show_value ("id",         $id);
	    show_value ("jobname",    $x->{jobname});
	    show_value ("resource",   $x->{job_resource});
	    show_value ("submit",     fmt_datetime($x->{submit_time}));
	    show_value ("start",      fmt_datetime($x->{start_time}));
	    show_value ("end",        fmt_datetime($x->{end_time}));
	    show_amt   ("memory",     $x->{memory});
	    show_value ("nodecount",  $x->{nodecount});
	    show_value ("processors", $x->{processors});
	    show_value ("queue",      $x->{queue});
	    show_amt   ("charge",     $x->{adjusted_charge});
	    print "\n";
	    if (option_flag('ja'))
	    {
		$job_id = $x->{job_id};
		$sql = "select * from jav where job_id = $job_id";
		@jav = db_select_rows($sql);
		foreach $jav (@jav)
		{
		    print "        job-attr";
		    show_value ("id",         $id);
		    show_value ("name",       $jav->{name});
		    show_value ("value",      $jav->{value});
		    print "\n";
		}
	    }
	}

	foreach $x (@cd)
	{
	    printf "     %s", $x->{type};
	    printf " resource=%s", $x->{site_resource_name};
	    printf " date=%s", fmt_datetime($x->{charge_date});
	    printf " amount=%s", fmt_amount(abs($x->{amount}));
	    print "\n";
	}

    }
    print "\n" if ($any);
    $any;
}

sub show_amt
{
    my($label, $amt) = @_;
    printf " %s=%s", $label, fmt_amount($amt) if (defined $amt);
}

sub show_value
{
    my($label, $value) = @_;
    printf " %s=%s", $label, $value if (defined $value);
}

sub fmt_name
{
    my($first_name, $middle_name, $last_name) = @_;
    my($name) = "$last_name, $first_name";
    $name .= " $middle_name" if $middle_name;
    my($name) = "$last_name, $first_name";
    $name .= " $middle_name" if $middle_name;
    return $name;
}

sub fmt_datetime
{
    my($dt) = shift;
    return undef unless (defined $dt);

    $dt =~ s/-\d\d$//;
    $dt =~ s/ /@/;
    $dt;
}

sub get_dates
{
    my($date);
    my($sdate, $edate, $edate2);

    $date = $options{'s'};
    if ($date)
    {
    	$sdate = ParseDate($date);
	error ("$date -- not a valid date") unless($sdate);
    }

    $date = $options{'e'};
    if ($date)
    {
	error ("-e requires -s") unless ($sdate);
    	$edate = ParseDate($date);
	error ("$date -- not a valid date") unless($edate);
	$edate2 = DateCalc ($edate, "+ 1 day");
    }

    $sdate  = UnixDate($sdate,  "%Y-%m-%d") if $sdate;
    $edate  = UnixDate($edate,  "%Y-%m-%d") if $edate;
    $edate2 = UnixDate($edate2, "%Y-%m-%d") if $edate2;

    error ("end date can't precede start date") if ($sdate && $edate && $sdate > $edate);

    ($sdate, $edate, $edate2);
}

# returns number (float) of SUs used by a given person_id on allocation_id
sub get_usage_on_allocation
{
    my($allocation_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/usage/by_allocation/%s/%s", 
      $rest_url, 
      uri_escape($allocation_id), 
      uri_escape($person_id));
    my $result = json_get($url);

    if ( defined $result->{result}[0]->{su_used} )
    {
	return $result->{result}[0]->{su_used};
    }

    return 0.0;
}

# return list of hashref of job info for a given allocation_id and person_id
sub get_jv_on_allocation
{
    my($allocation_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/jobs/by_allocation/%s/%s", 
      $rest_url, 
      uri_escape($allocation_id), 
      uri_escape($person_id));
    my $result = json_get($url);

    # caller expects a list
    if (scalar @{$result->{result}} < 1)
    {
	return ();
    }

    return @{$result->{result}};
}

# return list of hashref of credits/debits on allocation_id by person_id
sub get_cdv_on_allocation
{
    my($allocation_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/credits_debits/by_allocation/%s/%s", 
      $rest_url, 
      uri_escape($allocation_id), 
      uri_escape($person_id));
    my $result = json_get($url);

    # caller expects a list
    if (scalar @{$result->{result}} < 1)
    {
	return ();
    }

    return @{$result->{result}};
}

# return list of hashref of job info for a given account_id, resource_id,
# and person_id bounded by dates
sub get_jv_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/jobs/by_dates/%s/%s/%s/%s/%s", 
      $rest_url, 
      uri_escape($account_id), 
      uri_escape($resource_id),
      uri_escape($person_id),
      uri_escape($sdate),
      uri_escape(get_enddate()));
    my $result = json_get($url);

    # caller expects a list
    if (scalar @{$result->{result}} < 1)
    {
	return ();
    }

    return @{$result->{result}};
}

# return a list of hashref of credit/debit info given account_id, resource_id,
# person_id bounded by dates
sub get_cdv_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/credits_debits/by_dates/%s/%s/%s/%s/%s", 
      $rest_url, 
      uri_escape($account_id), 
      uri_escape($resource_id),
      uri_escape($person_id),
      uri_escape($sdate),
      uri_escape(get_enddate()));
    my $result = json_get($url);

    # caller expects a list
    if (scalar @{$result->{result}} < 1)
    {
	return ();
    }

    return @{$result->{result}};
}

# return a hashref of usage info given account_id, resource_id,
# and bounded by date
# optionally filtered by person_id
sub get_usage_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/usage/by_dates/%s/%s/%s/%s", 
      $rest_url, 
      uri_escape($account_id), 
      uri_escape($resource_id),
      uri_escape($sdate),
      uri_escape(get_enddate()));
    if ($person_id)
    {
	$url .= sprintf("?person_id=%s", uri_escape($person_id));
    }
    my $result = json_get($url);

    # caller expects just a hashref
    if ( scalar @{$result->{result}} < 1 )
    {
	return {};
    }

    return $result->{result}[0];
}

# return a string of credit/debit counts by type for a given account_id
# and resource_id, bounded by dates
# optionally filtered by person_id
# format is space-delmited, type=count[ ...]
sub get_counts_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/counts/by_dates/%s/%s/%s/%s", 
      $rest_url, 
      uri_escape($account_id), 
      uri_escape($resource_id),
      uri_escape($sdate),
      uri_escape(get_enddate()));
    if ($person_id)
    {
	$url .= sprintf("?person_id=%s", uri_escape($person_id));
    }
    my $result = json_get($url);

    # munge into a string according to some weird rules
    # original code will lowercase a type name if person_id is set and
    # evaluates to true... huh?  just emulating the same behavior.
    my $j = 0;
    my(@counts,$type,$n);
    my $lowercase = $person_id ? 1 : 0;
    foreach my $x (@{$result->{result}})
    {
    	($type, $n) = ($x->{type}, $x->{n});
	if ($type eq 'job')
	{
	    $j = $n
	}
	else
	{
	    $type .= 's' unless ($type eq 'storage');
	    $type = ucfirst($type) unless ($lowercase);
	    push @counts, "$type=$n";
	}
    }
    $type = $lowercase ? 'jobs' : 'Jobs';

    unshift @counts, "$type=$j";

    "@counts";
}

# return a string of credit/debit counts by type for a given allocation_id
# optionally filtered by person_id
# format is space-delmited, type=count[ ...]
sub get_counts_on_allocation
{
    my($allocation_id, $person_id) = @_;

    # construct a rest url and fetch it
    # don't forget to uri escape these things in case one has funny
    # characters
    my $url = sprintf("%s/xdusage/v1/counts/by_allocation/%s", 
      $rest_url, 
      uri_escape($allocation_id));
    if ($person_id)
    {
	$url .= sprintf("?person_id=%s", uri_escape($person_id));
    }
    my $result = json_get($url);

    # munge into a string according to some weird rules
    # original code will lowercase a type name if person_id is set and
    # evaluates to true... huh?  just emulating the same behavior.
    my $j = 0;
    my(@counts,$type,$n);
    my $lowercase = $person_id ? 1 : 0;
    foreach my $x (@{$result->{result}})
    {
    	($type, $n) = ($x->{type}, $x->{n});
	if ($type eq 'job')
	{
	    $j = $n
	}
	else
	{
	    $type .= 's' unless ($type eq 'storage');
	    $type = ucfirst($type) unless ($lowercase);
	    push @counts, "$type=$n";
	}
    }
    $type = $lowercase ? 'jobs' : 'Jobs';

    unshift @counts, "$type=$j";

    "@counts";
}

# return a suitable end date in UnixDate form
# uses edate2 if provided, otherwise today + 1 day
#
# needed since REST API requires an end date and
# end date is an optional argument.
sub get_enddate
{
    if (!$edate2)
    {
	return UnixDate(DateCalc(ParseDate('today'), "+ 1 day"), "%Y-%m-%d");
    }
    else
    {
	return $edate2;
    }
}

sub fmt_amount
{
    my($amt) = shift;
    return '0' if ($amt == 0);
    my($n) = 2;
    if (abs($amt) >= 10000)
    {
    	$n = 0;
    }
    elsif (abs($amt) >= 1000)
    {
    	$n = 1;
    }
    my($x) = sprintf ("%.*f", $n, $amt);

    while ($x == 0)
    {
    	$n++;
	$x = sprintf ("%.*f", $n, $amt);
    }
    $x =~ s/\.0*$//;
    $x = commas($x) unless (option_flag('nc'));
    $x;
}

sub error
{
    my(@msg) = @_;
    die "${me}: @msg\n";
}

# I got this from http://forrst.com/posts/Numbers_with_Commas_Separating_the_Thousands_Pe-CLe
sub commas
{
    my($x) = shift;
    my($neg) = 0;
    if ($x =~ /^-/)
    {
    	$neg = 1;
	$x =~ s/^-//;
    }
    $x =~ s/\G(\d{1,3})(?=(?:\d\d\d)+(?:\.|$))/$1,/g; 
    $x = "-" . "$x" if $neg;
    return $x; 
}
