package xCAT_plugin::slpdiscover;
use strict;
use xCAT::SvrUtils qw/sendmsg/;
use xCAT::SLP;
use xCAT::NetworkUtils;
use xCAT::SSHInteract;
use xCAT::MacMap;
use xCAT_plugin::bmcconfig;
my $defaultbladeuser;
my $defaultbladepass;
my $mpahash;

sub handled_commands {
	return {
		slpdiscover => "slpdiscover",
	};
};

my $callback;
my $docmd;
my %doneaddrs;
my %ip4neigh;
my %ip6neigh;
my %flexchassismap;
my %flexchassisuuid;
my %nodebymp;
my %passwordmap;
my %chassisbyuuid;
my %searchmacs;
my %researchmacs;
my $macmap;
sub get_mac_for_addr {
	my $neigh;
	my $addr = shift;
	if ($addr =~ /:/) {
		get_ipv6_neighbors();
		return $ip6neigh{$addr};
	} else {
		get_ipv4_neighbors();
		return $ip4neigh{$addr};
	}
}
sub get_ipv4_neighbors {
	#TODO: something less 'hacky'
	my @ipdata = `ip -4 neigh`;
	%ip6neigh=();
	foreach (@ipdata) {
		if (/^(\S*)\s.*lladdr\s*(\S*)\s/) {
			$ip4neigh{$1}=$2;
		}
	}
}
sub get_ipv6_neighbors {
	#TODO: something less 'hacky'
	my @ipdata = `ip -6 neigh`;
	%ip6neigh=();
	foreach (@ipdata) {
		if (/^(\S*)\s.*lladdr\s*(\S*)\s/) {
			$ip6neigh{$1}=$2;
		}
	}
}
sub handle_new_slp_entity {
	my $data = shift;
	delete $data->{sockaddr}; #won't need it
	my $mac = get_mac_for_addr($data->{peername});
	if ($data->{SrvType} eq "service:management-hardware.IBM:integrated-management-module2" and $data->{attributes}->{"enclosure-form-factor"}->[0] eq "BC2") {
		$data->{macaddress}=$mac;
		#this is a Flex ITE, don't go mac searching for it, but remember the chassis UUID for later
		push @{$flexchassismap{$data->{attributes}->{"chassis-uuid"}->[0]}},$data;
		return;
	}
	unless ($mac) { return; }
	$searchmacs{$mac} = $data;
}

sub process_request {
	my $request = shift;
	$callback = shift;
	$docmd = shift;
	%searchmacs=();
	%flexchassismap = ();
	my $srvtypes = [ qw/service:management-hardware.IBM:chassis-management-module service:management-hardware.IBM:management-module service:management-hardware.IBM:integrated-management-module2/ ];
	xCAT::SLP::dodiscover(SrvTypes=>$srvtypes,Callback=>\&handle_new_slp_entity);
	
	my $mpatab=xCAT::Table->new("mpa",-create=>0);
	my @mpaentries;
	$mpahash={};
	if ($mpatab) {
		@mpaentries = $mpatab->getAllNodeAttribs([qw/mpa username password/]);
		foreach (@mpaentries) {
			$mpahash->{$_->{mpa}}=$_;
		}
	}
	my $passwdtab=xCAT::Table->new("passwd",-create=>0);
	$defaultbladeuser="USERID";
	$defaultbladepass="";
	if ($passwdtab) {
		my @ents = $passwdtab->getAttribs({key=>'blade'},'username','password');
		foreach (@ents) {
			if ($_->{username} eq "HMC") { next; }
			if ($_->{username}) { $defaultbladeuser=$_->{username}; }
			if ($_->{password}) { $defaultbladepass=$_->{password}; }
		}
	}
	my $mactab = xCAT::Table->new("mac");
	my %machash;
	my %node2machash;
	my %macuphash;
	my @maclist = $mactab->getAllNodeAttribs([qw/node mac/]);
	foreach (@maclist) {
		$machash{$_->{node}}=$_->{mac};
		$node2machash{$_->{mac}} = $_->{node};
	}
	
	my $mptab = xCAT::Table->new('mp');
	if ($mptab) {
		my @mpents = $mptab->getAllNodeAttribs(['node','mpa','id']);
		foreach (@mpents) {
			$nodebymp{$_->{mpa}}->{$_->{id}}=$_->{node};
		}
	}

	$macmap = xCAT::MacMap->new();
	$macmap->refresh_table();
	my @toconfig;
	foreach my $mac (keys(%searchmacs)) {
		my $node = $macmap->find_mac($mac,1);
		unless ($node) {
			if (defined $node2machash{$mac}) {
				$node = $node2machash{$mac};
			} else {
				next;
			}
		}
		my $data = $searchmacs{$mac};
		$data->{nodename}=$node;
		$data->{macaddress}=$mac;
		$chassisbyuuid{$data->{attributes}->{"enclosure-uuid"}->[0]}=$node;
		push @toconfig,$data;
	}

	foreach my $data (@toconfig) {
		my $mac = $data->{macaddress};
		my $nodename = $data->{nodename};
		my $addr = $data->{peername}; #todo, use sockaddr and remove the 427 port from it instead?
		if ($addr =~ /^fe80/) { #Link local address requires scope index
			$addr .= "%".$data->{scopeid};
		}
		$flexchassisuuid{$nodename}=$data->{attributes}->{"enclosure-uuid"}->[0];
		
		if ($data->{SrvType} eq "service:management-hardware.IBM:chassis-management-module") {
			sendmsg(":Found ".$data->{SrvType}." at address $addr",$callback,$nodename);
			
			setup_cmm_pass($nodename);
			if ($machash{$nodename} =~ /$mac/i) { #ignore prospects already known to mac table
				configure_hosted_elements($nodename);
				next;
			}
		
			unless (do_blade_setup($data,curraddr=>$addr)) {
				next;
			}
			configure_hosted_elements($nodename);
			unless (do_blade_setup($data,curraddr=>$addr,pass2=>1)) {
				next;
			}
			sendmsg(":Configuration complete, configuration may take a few minutes to take effect",$callback,$nodename);
			$macuphash{$nodename} = { mac => $mac };
		}
	}
	$mactab->setNodesAttribs(\%macuphash);
}

sub setupIMM {
	my $node = shift;
	my %args = @_;
	my $slpdata = $args{slpdata};
	my $ipmitab = xCAT::Table->new('ipmi',-create=>0);
	unless ($ipmitab) { die "ipmi settings required to set up imm in xCAT" }
	my $ient = $ipmitab->getNodeAttribs($node,[qw/bmc bmcid/],prefetchcache=>1);
	my $newaddr;
	if ($ient) {
		my $bmcid=$ient->{bmcid};
		if ($bmcid and $slpdata->{macaddress} =~ /$bmcid/) { 
			sendmsg("The IMM ".$node." has been configured (ipmi.bmcid). Skipped.",$callback);
			return; 
		} #skip configuration, we already know this one
		$newaddr = $ient->{bmc};
	}
	my @ips;
	if ($newaddr) {
		@ips = xCAT::NetworkUtils::getipaddr($newaddr,GetAllAddresses=>1);
	}
	if (!@ips) {
		sendmsg(":Cannot find the IP attribute for bmc",$callback,$node);
		return;
	}
	sendmsg(":Configuration of ".$node."[".join(',',@ips)."] commencing, configuration may take a few minutes to take effect",$callback);
	#ok, with all ip addresses in hand, time to enable IPMI and set all the ip addresses (still static only, TODO: dhcp
	my $ssh = new xCAT::SSHInteract(-username=>$args{username},
					-password=>$args{password},
					-host=>$args{curraddr},
					-nokeycheck=>1,
					-output_record_separator=>"\r",
					Timeout=>15,
					Errmode=>'return',
					Prompt=>'/MYIMM> $/');
	if ($ssh and $ssh->atprompt) { #we are in and good to issue commands
		$ssh->cmd("users -1 -n ".$args{username}." -p ".$args{password}." -a super"); #this gets ipmi going
		foreach my $ip (@ips) {
			if ($ip =~ /:/) { 
				$ssh->cmd("ifconfig eth0 -ipv6static enable -i6 $ip");
			} else {
				(my $sip,my $mask,my $gw) = xCAT_plugin::bmcconfig::net_parms($ip);
				$ssh->cmd("ifconfig eth0 -c static -i $ip -s $mask -g $gw");
			}
		}
		$ssh->close();
		$ipmitab->setNodeAttribs($node,{bmcid=>$slpdata->{macaddress}});
	}
}

sub configure_hosted_elements {
	my $cmm = shift;
	my $uuid=$flexchassisuuid{$cmm};
	my $node;
	my $immdata;
	my $slot;
	my $user = $passwordmap{$cmm}->{username};
	my $pass = $passwordmap{$cmm}->{password};
	foreach $immdata (@{$flexchassismap{$uuid}}) {
		$slot=$immdata->{attributes}->{slot}->[0];
		if ($node = $nodebymp{$cmm}->{$slot}) {
			my $addr = $immdata->{peername}; #todo, use sockaddr and remove the 427 port from it instead?
			if ($addr =~ /^fe80/) { #Link local address requires scope index
				$addr .= "%".$immdata->{scopeid};
			}
			if ($doneaddrs{$node}) { next; }
			$doneaddrs{$node}=1;
			setupIMM($node,slpdata=>$immdata,curraddr=>$addr,username=>$user,password=>$pass);
		}
	}
}

sub setup_cmm_pass {
	my $nodename = shift;
	my $localuser=$defaultbladeuser;
	my $localpass=$defaultbladepass;
	if ($mpahash->{$nodename}) {
		if ($mpahash->{$nodename}->{username}) {
			$localuser = $mpahash->{$nodename}->{username};
		}
		if ($mpahash->{$nodename}->{password}) {
			$localpass = $mpahash->{$nodename}->{password};
		}
	}
        $passwordmap{$nodename}->{username}=$localuser;
        $passwordmap{$nodename}->{password}=$localpass;
}
sub do_blade_setup {
	my $data = shift;
	my %args = @_;
	my $addr = $args{curraddr};
	my $nodename = $data->{nodename};
	my $localuser=$passwordmap{$nodename}->{username};
	my $localpass=$passwordmap{$nodename}->{password};
	if (not $localpass or $localpass eq "PASSW0RD") {
		sendmsg([1,":Password for blade must be specified in either mpa or passwd tables, and it must not be PASSW0RD"],$callback,$nodename);
		return 0;
	}
	require xCAT_plugin::blade;
	my @cmds;
	my %exargs;
	if ($args{pass2}) {
	  @cmds = qw/initnetwork=*/; 
	  %exargs = ( nokeycheck=>1 ); #still not at the 'right' ip, so the known hosts shouldn't be bothered
	} else {
	  @cmds = qw/snmpcfg=enable sshcfg=enable textid=*/; # initnetwork=*/; defer initnetwork until after chassis members have been configured
	  %exargs = ( defaultcfg=>1 );
        }
	my $result;
	my $rc = eval { $result = xCAT_plugin::blade::clicmds(
						 $nodename,
						 $localuser,
						 $localpass,
						 $nodename,
						 0,
						 curraddr=>$addr,
						 %exargs,
						 cmds=>\@cmds );
		1;
	};
        if (not $rc) {
		sendmsg([1,"Failed to set up Management module due to $@"],$callback,$nodename);
	}
	if ($result) {
		if ($result->[0]) {
			sendmsg([$result->[0],$result->[2]],$callback,$nodename);
		}
	}
	return $rc;
}
1;
