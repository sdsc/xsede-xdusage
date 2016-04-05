#!/usr/bin/env perl
use strict;
use DBI;
use Getopt::Long;
use Date::Manip;

Getopt::Long::Configure ("no_ignore_case");

my $PASSWORD="xdusage";  # change to correct password as obtained from XDCDB admins
my($me) = (split /\//, $0)[-1];
my($logname)     = $ENV{SUDO_USER}           || die "SUDO_USER not set\n";
my($install_dir) = $ENV{XDUSAGE_INSTALL_DIR} || die "XDUSAGE_INSTALL_DIR not set\n";

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

my($resource) = get_resource();
my($is_admin) = is_admin($logname);
my($xuser) = ($is_admin && $ENV{USER}) ? $ENV{USER} : $logname;

my($dbh)      = db_connect();
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

sub db_connect
{
    my($host) = 'tgcdb.xsede.org';
    my($port) = 5432;
    my($dbh);

    if ($DEBUG)
    {
        $host = 'balthazar.sdsc.edu';
        $port = 3333;
    }
    $dbh = DBI->connect ("dbi:Pg:dbname=teragrid;host=$host;port=$port;sslmode=require", 'xdusage', $PASSWORD, 
                                 {RaiseError => 1, PrintError => 0}
                         );
    $dbh->do('set search_path to xdusage');
    $dbh;
}
sub db_disconnect
{
    $dbh->disconnect();
}

sub get_resource()
{
    my($file) =  "$install_dir/resource_name";
    my($name);

    die "${me}: $file - $!\n" unless open FD, $file;
    while (<FD>)
    {
        chomp;
        $name = $_;
    }
    close FD;
    $name;
}

sub is_admin()
{
    my($user) = shift;
    my($file) =  "$install_dir/xdusage.admins";
    my($name);
    my($is_admin) = 0;

    return 0 unless (-r $file);
    die "${me}: $file - $!\n" unless open FD, $file;
    while (<FD>)
    {
        chomp;
        $name = $_;
	$is_admin = 1 if ($user eq $name);
    }
    close FD;
    $is_admin;
}

sub get_user
{
    my($username, $portal) = @_;
    my($rs) = $portal ? 'portal.teragrid' : $resource;
    my($sql) = sprintf ("select distinct person_id, last_name, first_name, is_su
                         from userv where username like %s and resource_name=%s",
                          $dbh->quote($username),
                          $dbh->quote($rs),
                        );

    db_select_rows ($sql);
}

sub get_users_by_last_name
{
    my($name) = shift;
    my($sql) = sprintf ("select distinct person_id, last_name, first_name, is_su
                         from userv where last_name like %s",
                          $dbh->quote($name),
                        );

    db_select_rows ($sql);
}

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

sub get_resources
{
    my(@resources) = ();
    my($name, $r, $sql);
    my($pat);
    my($any);

    foreach $name (option_list('r'))
    {
	$pat = $name;
	$pat = "$pat.%" unless ($name =~ /[.%]/);
    	$sql = sprintf "select resource_id from rsv where resource_name like %s or resource_name = %s",
		$dbh->quote($pat), $dbh->quote($name);
	$any = 0;
	foreach $r (db_select_rows($sql))
	{
	    push @resources, $r->{resource_id};
	    $any = 1;
	}
	error ("$name - resource not found") unless ($any);
    }

    @resources;
}

sub get_projects
{
    return unless ($user);

    my($person_id) = $user->{person_id};
    my($is_su)     = $user->{is_su};
    my(@tables) = ("projv p");
    my(@where) = ();
    my($p, @p);

    unless ($is_su && @plist)
    {
        push @tables, "abxv a1";
        push @where, "p.account_id = a1.account_id";
        push @where, "p.resource_id = a1.resource_id";
        push @where, "a1.person_id = $person_id";
    }
    if (@plist)
    {
	@p = ();
	foreach $p (@plist)
	{
	    push @p, "lower(p.charge_number) like lower(" . $dbh->quote($p) . ")";
	    push @p, "lower(p.grant_number)  like lower(" . $dbh->quote($p) . ")";
	}
        push @where, '(' . join (' or ', @p) . ')';
    }
    else
    {
        push @where, "not p.is_expired";
    }
    push @where, "proj_state = 'active'" if (option_flag('ip'));
    if (@resources)
    {
        my($resources) = join (',', @resources);
        push @where, "p.resource_id in ($resources)";
    }

    my($where)  = join (' and ', @where);
    my($tables) = join (',', @tables);

    my($sql) = "select distinct p.* from $tables where $where order by grant_number, resource_name";

    db_select_rows ($sql);
}

sub get_allocation
{
    my($account_id, $resource_id, $previous) = @_;

    my($sql) = "select *
                  from av
                 where account_id = $account_id
                   and resource_id = $resource_id
                 order by alloc_start desc
		 limit 2
               ";

    my(@a) = db_select_rows($sql);

    $previous ? $a[1] : $a[0];
}

sub get_accounts
{
    my($project) = shift;
    my($person_id) = $user->{person_id};
    my($is_su)     = $user->{is_su};

    my($sql) = "select * from acctv
                 where account_id = $project->{account_id}
                   and resource_id = $project->{resource_id}\n
               ";
    if (@users || !(option_flag('a') || $is_su))
    {
        my($users) = @users ? join (',', map {$_->{person_id}} @users) : $person_id;
	$sql .= " and person_id in ($users)\n";
    }
    $sql .= " and acct_state = 'active'\n" if (option_flag('ia'));
    $sql .= "\norder by is_pi desc, last_name, first_name\n";
    db_select_rows ($sql);
}

sub db_select_rows
{
    my($sql) = shift;
    my(@rows) = ();
    my($sth, $row);

    $sth = $dbh->prepare ($sql);
    $sth->execute;
    while ($row = $sth->fetchrow_hashref)
    {
        push @rows, $row
    }
    $sth->finish;

    @rows;
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

sub get_usage_on_allocation
{
    my($allocation_id, $person_id) = @_;

    my($sql) = "select su_used from abv where allocation_id = $allocation_id and person_id = $person_id";
    my($x) = db_select_rows($sql);

    return $x ? $x->{su_used} : 0;
}

sub get_jv_on_allocation
{
    my($allocation_id, $person_id) = @_;

    my($sql) = "select * from jv where allocation_id = $allocation_id and person_id = $person_id";
    $sql .= " order by submit_time, local_jobid";
    db_select_rows($sql);
}

sub get_cdv_on_allocation
{
    my($allocation_id, $person_id) = @_;

    my($sql) = "select * from cdv where allocation_id = $allocation_id and person_id = $person_id";
    $sql .= " order by type, charge_date";
    db_select_rows($sql);
}

sub get_jv_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    my($sql) = "select * from jv where account_id = $account_id and resource_id = $resource_id";
    $sql .= " and person_id = $person_id";
    $sql .= date_clause();
    $sql .= " order by submit_time, local_jobid";

    db_select_rows($sql);
}

sub get_cdv_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    my($sql) = "select * from cdv where account_id = $account_id and resource_id = $resource_id";
    $sql .= " and person_id = $person_id";
    $sql .= date_clause();
    $sql .= " order by type, charge_date";

    db_select_rows($sql);
}

sub get_usage_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;

    my($sql) = "select min(charge_date)::date as start_date,
                       max(charge_date)::date as end_date,
		       sum(charge) as su_used
		  from usagev
		 where account_id = $account_id
		   and resource_id = $resource_id";
    $sql .= " and person_id = $person_id" if (defined $person_id);
    $sql .= date_clause();

    my($x) = db_select_rows($sql);
    $x;
}

sub get_counts_by_dates
{
    my($account_id, $resource_id, $person_id) = @_;
    my($where) = "account_id=$account_id and resource_id=$resource_id";
    $where .= " and person_id=$person_id" if (defined $person_id);
    $where .= date_clause();
    get_counts($where, $person_id);
}

sub get_counts_on_allocation
{
    my($allocation_id, $person_id) = @_;
    my($where) = "allocation_id=$allocation_id";
    $where .= " and person_id=$person_id" if (defined $person_id);
    get_counts($where, $person_id);
}

sub get_counts
{
    my($where, $lowercase) = @_;
    my(@counts) = ();
    my($j) = 0;
    my(@x, $x);
    my($type, $n);

    @x = db_select_rows ("select type, count(*) as n from usagev where $where group by type order by type");
    foreach $x (@x)
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

sub date_clause
{
    my($sql) = '';
    $sql .= " and charge_date >= '$sdate'"  if ($sdate);
    $sql .= " and charge_date <  '$edate2'" if ($edate2);
    $sql;
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