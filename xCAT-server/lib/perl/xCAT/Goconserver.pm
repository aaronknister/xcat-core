#!/usr/bin/perl
## IBM(c) 2107 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::Goconserver;

BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use warnings "all";
use File::Copy qw(move);

use HTTP::Request;
use HTTP::Headers;
use LWP;
use JSON;
use File::Path;
use IO::Socket::SSL qw( SSL_VERIFY_PEER );

my $go_api_port = 12429;
my $go_cons_port = 12430;
my $bmc_cons_port = "2200";

use constant CONSOLE_LOG_DIR => "/var/log/consoles";
use constant PRINT_FORMAT => "%-32s %-32s %-64s";
unless (-d CONSOLE_LOG_DIR) {
    mkpath(CONSOLE_LOG_DIR, 0, 0755);
}

sub http_request {
    my ($method, $url, $data) = @_;
    my @user          = getpwuid($>);
    my $homedir       = $user[7];
    my $rsp;
    my $brower = LWP::UserAgent->new( ssl_opts => {
            SSL_key_file    => xCAT::Utils->getHomeDir() . "/.xcat/client-cred.pem",
            SSL_cert_file   => xCAT::Utils->getHomeDir() . "/.xcat/client-cred.pem",
            SSL_ca_file     => xCAT::Utils->getHomeDir() . "/.xcat/ca.pem",
            SSL_use_cert    => 1,
            verify_hostname => 0,
            SSL_verify_mode => SSL_VERIFY_PEER,  }, );
    my $header = HTTP::Headers->new('Content-Type' => 'application/json');
    #    $data = encode_json $data if defined($data);
    $data = JSON->new->encode($data) if defined($data);
    my $request = HTTP::Request->new( $method, $url, $header, $data );
    my $response = $brower->request($request);
    if (!$response->is_success()) {
        xCAT::MsgUtils->message("S", "Failed to send request to $url, rc=".$response->status_line());
        return undef;
    }
    my $content = $response->content();
    if ($content) {
        return decode_json $content;
    }
    return "";
}

sub gen_request_data {
    my ($cons_map, $siteondemand, $isSN, $callback) = @_;
    my (@openbmc_nodes, $data);
    while (my ($k, $v) = each %{$cons_map}) {
        my $ondemand;
        if ($siteondemand) {
            $ondemand = \1;
        } else {
            $ondemand = \0;
        }
        my $cmd;
        my $cmeth  = $v->{cons};
        if ($cmeth eq "openbmc") {
            push @openbmc_nodes, $k;
        }  else {
            $cmd = $::XCATROOT . "/share/xcat/cons/$cmeth"." ".$k;
            if (!(!$isSN && $v->{conserver} && xCAT::NetworkUtils->thishostisnot($v->{conserver}))) {
                my $env;
                my $locerror = $isSN ? "PERL_BADLANG=0 " : '';
                if (defined($ENV{'XCATSSLVER'})) {
                    $env = "XCATSSLVER=$ENV{'XCATSSLVER'} ";
                }
                $cmd = $locerror.$env.$cmd;
            }
            $data->{$k}->{driver} = "cmd";
            $data->{$k}->{params}->{cmd} = $cmd;
            $data->{$k}->{name} = $k;
        }
        if (defined($v->{consoleondemand})) {
            # consoleondemand attribute for node can be "1", "yes", "0" and "no"
            if (($v->{consoleondemand} eq "1") || lc($v->{consoleondemand}) eq "yes") {
                $ondemand = \1;
            }
            elsif (($v->{consoleondemand} eq "0") || lc($v->{consoleondemand}) eq "no") {
                $ondemand = \0;
            }
        }
        $data->{$k}->{ondemand} = $ondemand;
    }
    if (@openbmc_nodes) {
        my $passwd_table = xCAT::Table->new('passwd');
        my $passwd_hash = $passwd_table->getAttribs({ 'key' => 'openbmc' }, qw(username password));
        $passwd_table->close();
        my $openbmc_table = xCAT::Table->new('openbmc');
        my $openbmc_hash = $openbmc_table->getNodesAttribs(\@openbmc_nodes, ['bmc','consport', 'username', 'password']);
        $openbmc_table->close();
        foreach my $node (@openbmc_nodes) {
            if (defined($openbmc_hash->{$node}->[0])) {
                if (!$openbmc_hash->{$node}->[0]->{'bmc'}) {
                    if($callback) {
                        xCAT::SvrUtils::sendmsg("Error: Unable to get attribute bmc", $callback, $node);
                    } else {
                        xCAT::MsgUtils->message("S", "$node: Error: Unable to get attribute bmc");
                    }
                    delete $data->{$node};
                    next;
                }
                $data->{$node}->{params}->{host} = $openbmc_hash->{$node}->[0]->{'bmc'};
                if ($openbmc_hash->{$node}->[0]->{'username'}) {
                    $data->{$node}->{params}->{user} = $openbmc_hash->{$node}->[0]->{'username'};
                } elsif ($passwd_hash and $passwd_hash->{username}) {
                    $data->{$node}->{params}->{user} = $passwd_hash->{username};
                } else {
                    if ($callback) {
                        xCAT::SvrUtils::sendmsg("Error: Unable to get attribute username", $callback, $node)
                    } else {
                        xCAT::MsgUtils->message("S", "$node: Error: Unable to get attribute username");
                    }
                    delete $data->{$node};
                    next;
                }
                if ($openbmc_hash->{$node}->[0]->{'password'}) {
                    $data->{$node}->{params}->{password} = $openbmc_hash->{$node}->[0]->{'password'};
                } elsif ($passwd_hash and $passwd_hash->{password}) {
                    $data->{$node}->{params}->{password} = $passwd_hash->{password};
                } else {
                    if ($callback) {
                        xCAT::SvrUtils::sendmsg("Error: Unable to get attribute password", $callback, $node)
                    } else {
                        xCAT::MsgUtils->message("S", "$node: Error: Unable to get attribute password");
                    }
                    delete $data->{$node};
                    next;
                }
                if ($openbmc_hash->{$node}->[0]->{'consport'}) {
                    $data->{$node}->{params}->{consport} = $openbmc_hash->{$node}->[0]->{'consport'};
                } else {
                    $data->{$node}->{params}->{port} = $bmc_cons_port;
                }
                $data->{$node}->{name} = $node;
                $data->{$node}->{driver} = "ssh";
            }
        }
    }
    return $data;
}

#-------------------------------------------------------------------------------

=head3  init_local_console
        Init console nodes on service node locally.

    Globals:
        none
    Example:
         my $ready=(xCAT::Goconserver::init_local_console()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub init_local_console {
    my @hostinfo = xCAT::NetworkUtils->determinehostname();
    my %iphash   = ();
    my %cons_map;
    my $ret;
    my $host = $hostinfo[-1];
    foreach (@hostinfo) {
        $iphash{$_} = 1;
    }
    my $retry = 0;
    my $api_url = "https://$host:". get_api_port();
    my $response = http_request("GET", $api_url."/nodes");
    while(!defined($response) && $retry < 3) {
        $response = http_request("GET", $api_url."/nodes");
        $retry ++;
        sleep 1;
    }
    if (!defined($response)) {
        xCAT::MsgUtils->message("S", "Could not connect to goconserver after trying 3 times.");
        return;
    }
    if ($response->{nodes}->[0]) {
        # node data exist, maybe this is not diskless sn.
        return;
    }
    my $nodehmtab = xCAT::Table->new('nodehm', -create => 1);
    if (!$nodehmtab) {
        return;
    }
    my @cons_nodes = $nodehmtab->getAllNodeAttribs([ 'node', 'cons', 'serialport', 'mgt', 'conserver', 'consoleondemand', 'consoleenabled' ]);
    $nodehmtab->close();
    my @nodes = ();
    foreach (@cons_nodes) {
        if ($_->{consoleenabled} && ($_->{cons} or defined($_->{'serialport'}))) {
            unless ($_->{cons}) {
                $_->{cons} = $_->{mgt};
            }
            if ($_->{conserver} && exists($iphash{ $_->{conserver} })) {
                $cons_map{ $_->{node} } = $_;
            }
        }
    }
    my @entries    = xCAT::TableUtils->get_site_attribute("consoleondemand");
    my $site_entry = $entries[0];
    my $siteondemand = 0;
    if (defined($site_entry)) {
        if (lc($site_entry) eq "yes") {
            $siteondemand = 1;
        }
        elsif (lc($site_entry) ne "no") {
            xCAT::MsgUtils->message("S", $host.": Unexpected value $site_entry for consoleondemand attribute in site table");
        }
    }
    my $data = gen_request_data(\%cons_map, $siteondemand, 1, undef);
    if (! $data) {
        xCAT::MsgUtils->message("S", $host.": Could not generate the request data");
        return;
    }
    if (create_nodes($api_url, $data, undef)) {
        xCAT::MsgUtils->message("S", $host.": Failed to create console entry in goconserver. ");
    }
}

sub disable_nodes_in_db {
    my $nodes = shift;
    my $nodehmtab = xCAT::Table->new('nodehm', -create => 1);
    if (!$nodehmtab) {
        return 1;
    }
    my $updateattribs->{consoleenabled} = undef;
    $nodehmtab->setNodesAttribs($nodes, $updateattribs);
    $nodehmtab->close();
    return 0;
}

sub enable_nodes_in_db {
    my $nodes = shift;
    my $nodehmtab = xCAT::Table->new('nodehm', -create => 1);
    if (!$nodehmtab) {
        return 1;
    }
    my $updateattribs->{consoleenabled} = '1';
    $nodehmtab->setNodesAttribs($nodes, $updateattribs);
    $nodehmtab->close();
    return 0;
}

sub delete_nodes {
    my ($api_url, $node_map, $delmode, $callback) = @_;
    my $url = "$api_url/bulk/nodes";
    my @a = ();
    my ($data, $rsp, $ret, @update_nodes);
    $data->{nodes} = \@a;
    foreach my $node (keys %{$node_map}) {
        my $temp;
        $temp->{name} = $node;
        push @a, $temp;
    }
    $ret = 0;
    my $response = http_request("DELETE", $url, $data);
    if (!defined($response)) {
        if ($callback) {
            $rsp->{data}->[0] = "Failed to send delete request.";
            xCAT::MsgUtils->message("E", $rsp, $callback)
        } else {
            xCAT::MsgUtils->message("S", "Failed to send delete request.");
        }
        return 1;
    } elsif ($delmode) {
        while (my ($k, $v) = each %{$response}) {
            if ($v ne "Deleted") {
                if ($callback) {
                    $rsp->{data}->[0] = "$k: Failed to delete entry in goconserver: $v";
                    xCAT::MsgUtils->message("E", $rsp, $callback)
                } else {
                    xCAT::MsgUtils->message("S", "$k: Failed to delete entry in goconserver: $v");
                }
                $ret = 1;
            } else {
                if ($callback) {
                    $rsp->{data}->[0] = "$k: $v";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
                push(@update_nodes, $k);
            }
        }
    }
    if (@update_nodes) {
        if (disable_nodes_in_db(\@update_nodes)) {
            if ($callback) {
                $rsp->{data}->[0] = "Failed to update consoleenabled status in db.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
            } else {
                xCAT::MsgUtils->message("S", "Failed to update consoleenabled status in db.");
            }
        }
    }
    return $ret;
}

sub create_nodes {
    my ($api_url, $node_map, $callback) = @_;
    my $url = "$api_url/bulk/nodes";
    my ($data, $rsp, @a, $ret, @update_nodes);
    $data->{nodes} = \@a;
    while (my ($k, $v) = each %{$node_map}) {
        push @a, $v;
    }
    $ret = 0;
    my $response = http_request("POST", $url, $data);
    if (!defined($response)) {
        if ($callback) {
            $rsp->{data}->[0] = "Failed to send create request.";
            xCAT::MsgUtils->message("E", $rsp, $callback)
        } else {
            xCAT::MsgUtils->message("S", "Failed to send create request.");
        }
        return 1;
    } elsif ($response) {
        while (my ($k, $v) = each %{$response}) {
            if ($v ne "Created") {
                if ($callback) {
                    $rsp->{data}->[0] = "$k: Failed to create console entry in goconserver: $v";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                } else {
                    xCAT::MsgUtils->message("S", "$k: Failed to create console entry in goconserver: $v");
                }
                $ret = 1;
            } else {
                $rsp->{data}->[0] = "$k: $v";
                xCAT::MsgUtils->message("I", $rsp, $callback) if $callback;
                push(@update_nodes, $k);
            }
        }
    }
    if (@update_nodes) {
        if (enable_nodes_in_db(\@update_nodes)) {
            if ($callback) {
                $rsp->{data}->[0] = "Failed to update consoleenabled status in db.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
            } else {
                CAT::MsgUtils->message("S", "Failed to update consoleenabled status in db.");
            }
        }
    }
    return $ret;
}

sub list_nodes {
    my ($api_url, $node_map, $callback) = @_;
    my $url = "$api_url/nodes";
    my $rsp;
    my $response = http_request("GET", $url);
    if (!defined($response)) {
        $rsp->{data}->[0] = "Failed to send list request.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
    if (!$response->{nodes}) {
        $rsp->{data}->[0] = "Could not find any node.";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 0;
    }
    $rsp->{data}->[0] = sprintf("\n".PRINT_FORMAT, "NODE", "SERVER", "STATE");
    xCAT::MsgUtils->message("I", $rsp, $callback);
    foreach my $node (sort {$a->{name} cmp $b->{name}} @{$response->{nodes}}) {
        if (!$node_map->{$node->{name}}) {
            next;
        }
        $node_map->{$node->{name}}->{vis} = 1;
        if (!$node->{host} || !$node->{state}) {
            $rsp->{data}->[0] = sprintf(PRINT_FORMAT, $node->{name}, "", "Unable to parse the response message");
            xCAT::MsgUtils->message("E", $rsp, $callback);
            next;
        }
        $rsp->{data}->[0] = sprintf(PRINT_FORMAT, $node->{name}, $node->{host}, $node->{state});
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
    my %node_hash = %{$node_map};
    for my $node (sort keys %node_hash) {
        if(!$node_hash{$node}->{vis}) {
            $rsp->{data}->[0] = sprintf(PRINT_FORMAT, $node, "", "unregistered");
            xCAT::MsgUtils->message("I", $rsp, $callback);
        }
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  is_xcat_conf_ready
        Check if the goconserver configuration file was generated by xcat

    Returns:
        1 - ready
        0 - not ready
    Globals:
        none
    Example:
         my $ready=(xCAT::Goconserver::is_xcat_conf_ready()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub is_xcat_conf_ready {
    my $file;
    open $file, '<', "/etc/goconserver/server.conf";
    my $line = <$file>;
    close $file;
    if ($line =~ /#generated by xcat/) {
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  is_goconserver_running
        Check if the goconserver service is running

    Returns:
        1 - running
        0 - not running
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::is_goconserver_running()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub is_goconserver_running {
    my $cmd = "ps axf | grep -v grep | grep \/usr\/bin\/goconserver";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        return 0;
    }
    return 1;
}

#-------------------------------------------------------------------------------

=head3  is_conserver_running
        Check if the conserver service is running

    Returns:
        1 - running
        0 - not running
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::is_conserver_running()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub is_conserver_running {
    # On ubuntu system 'service conserver status' can not get the correct status of conserver,
    # use 'pidof conserver' like what we did in rcons.
    my $cmd = "pidof conserver";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC == 0) {
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  build_conf
        generate configuration file for goconserver

    Returns:
        none
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::build_conf()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub build_conf {
    # try to backup the original configuration file, no matter sunccess or not
    move('/etc/goconserver/server.conf', '/etc/goconserver/server.conf.bak');
    my $config = "#generated by xcat ".xCAT::Utils->Version()."\n".
                 "global:\n".
                 "  host: 0.0.0.0\n".
                 "  ssl_key_file: /etc/xcat/cert/server-cred.pem\n".
                 "  ssl_cert_file: /etc/xcat/cert/server-cred.pem\n".
                 "  ssl_ca_cert_file: /etc/xcat/cert/ca.pem\n".
                 "  logfile: /var/log/goconserver/server.log             # the log for goconserver\n".
                 "api:\n".
                 "  port: $go_api_port                                   # the port for rest api\n".
                 "console:\n".
                 "  datadir: /var/lib/goconserver/                       # the data file to save the hosts\n".
                 "  port: $go_cons_port                                  # the port for console\n".
                 "  log_timestamp: true                                  # log the timestamp at the beginning of line\n".
                 "  # time precison for tcp or udp logger, precison for file logger is always second\n".
                 "  time_precision: microsecond                          # Valid options: second, millisecond, microsecond, nanosecond\n".
                 "  reconnect_interval: 10                               # retry interval in second if console could not be connected\n".
                 "  logger:                                              # multiple logger targets could be specified\n".
                 "    file:                                              # file logger, valid fields: name,logdir. Accept array in yaml format\n".
                 "       - name: default                                 # the identity name customized by user\n".
                 "         logdir: ".CONSOLE_LOG_DIR."                   # default log directory of xcat\n".
                 "    #  - name: goconserver                             \n".
                 "    #    logdir: /var/log/goconserver/nodes            \n".
                 "  # tcp:                                               # valied fields: name, host, port, timeout, ssl_key_file, ssl_cert_file, ssl_ca_cert_file, ssl_insecure\n".
                 "     # - name: logstash                                \n".
                 "     #   host: 127.0.0.1                               \n".
                 "     #   port: 9653                                    \n".
                 "     #   timeout:  3                                   # default 3 second\n".
                 "     # - name: filebeat                                \n".
                 "     #   host: <hostname or ip>                        \n".
                 "     #   port: <port>                                  \n".
                 "  # udp:                                               # valid fiedls: name, host, port, timeout\n".
                 "     # - name: rsyslog                                 \n".
                 "     #   host:                                         \n".
                 "     #   port:                                         \n".
                 "     #   timeout:                                      # default 3 second\n";

    my $file;
    my $ret = open ($file, '>', '/etc/goconserver/server.conf');
    if ($ret == 0) {
        xCAT::MsgUtils->message("S", "Could not open file /etc/goconserver/server.conf");
        return 1;
    }
    print $file $config;
    close $file;
    return 0;
}

#-------------------------------------------------------------------------------

=head3  start_service
        start goconserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::start_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub start_service {
    my $cmd = "service goconserver start";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not start goconserver service.");
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  stop_service
        stop goconserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $ret=(xCAT::Goconserver::stop_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub stop_service {
    my $cmd = "service goconserver stop";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not stop goconserver service.");
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  stop_conserver_service
        stop conserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $ret=(xCAT::Goconserver::stop_conserver_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub stop_conserver_service {
    my $cmd = "service conserver stop";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not stop conserver service.");
        return 1;
    }
    return 0;
}
#-------------------------------------------------------------------------------

=head3  restart_service
        restart goconserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $ret=(xCAT::Goconserver::restart_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub restart_service {
    my $cmd = "service goconserver restart";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not restart goconserver service.");
        return 1;
    }
    return 0;
}


sub get_api_port {
    return $go_api_port;
}
1;