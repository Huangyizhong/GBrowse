package Bio::Graphics::Browser2::Render::Slave::AWS_Balancer;

# This module is used to manage GBrowse slaves in an on-demand Amazon EC2
# environment.

use strict;
use Parse::Apache::ServerStatus;
use VM::EC2;
use VM::EC2::Instance::Metadata;
use LWP::Simple 'get','head';
use Parse::Apache::ServerStatus;
use Carp 'croak';

sub new {
    my $class = shift;
    my ($conf_file,$access_key,$secret_key) = @_;
    #setup defaults
    $ENV{EC2_ACCESS_KEY} = $access_key if defined $access_key;
    $ENV{EC2_SECRET_KEY} = $secret_key if defined $secret_key;
    my $self = bless {
	conf_file => $conf_file,
    },ref $class || $class;
    $self->initialize();
    return $self;
}

#######################
# configuration
######################

sub conf_file {shift->{conf_file}}

sub load_table {
    return shift->{options}{'LOAD TABLE'};
}

sub option {
    my $self = shift;
    my ($stanza,$option) = @_;
    return $self->{options}{uc $stanza}{$option};
}

# given load, returns two element list of min_instances, max_instances
sub slaves_wanted {
    my $self = shift;
    my $load = shift;

    my $lt   = $self->load_table or croak 'no load table!';
    my ($min,$max) = (0,0);
    for my $l (sort {$a<=>$b} keys %$lt) {
	($min,$max) = @{$lt->{$l}} if $load >= $l;
    }
    return ($min,$max);
}

sub slave_instance_type { shift->option('SLAVE','instance_type') || 'm1.large' }
sub slave_spot_bid      { shift->option('SLAVE','spot_bid')      || 0.08       }
sub slave_ports         { my $p = shift->option('SLAVE','ports');
			  my @p = split /\s+/,$p;
			  return @p ? @p : (8101); }
sub slave_region          {
    my $self = shift;
    if ($self->running_as_instance) {
	my $zone =  $self->{instance_metadata}->availabilityZone;
	$zone    =~ s/[a-z]$//;  #  zone=>region
	return $zone;
    } else {
	return $self->option('SLAVE','region') || 'us-east-1';
    }
}

sub slave_zone {
    my $self = shift;
    if ($self->running_as_instance) {
	return $self->{instance_metadata}->availabilityZone;
    } else {
	$self->option('SLAVE','availability_zone');
    }
}

sub slave_image_id {
    my $self = shift;
    if ($self->running_as_instance) {
	return $self->{instance_metadata}->imageId;
    } else {
	$self->option('SLAVE','image_id');
    }
}

sub slave_subnet {
    my $self = shift;
    if ($self->running_as_instance) {
	return eval {(values %{$self->{instance_metadata}->interfaces})[0]{subnetId}};
    } else {
	$self->option('SLAVE','subnet');
    }
}

sub slave_security_group {
    my $self = shift;
    my $sg   = $self->{slave_security_group};
    return $sg if $sg;
    my $ec2 = $self->ec2;
    $sg =   $ec2->describe_security_groups(-name     =>  "GBROWSE_SLAVE_$$");
    $sg ||= $ec2->create_security_group(-name        =>  "GBROWSE_SLAVE_$$",
					-description => 'Temporary security group for slave communications');
    my @auth;
    if ($self->running_as_instance) {
	@auth = (-group => $self->master_security_group);
    } else {
	@auth = (-source_ip => $self->master_ip.'/32');
    }
    $sg->authorize_incoming(-protocol  => 'tcp',
			    -port      => $_,
			    @auth) foreach $self->slave_ports;
    $sg->update;
    return $self->{slave_security_group} = $sg;
}

sub ec2 {
    my $self = shift;
    return $self->{ec2} if exists $self->{ec2};
    my $region = $self->slave_region;
    return $self->{ec2} = VM::EC2->new(-region=>$region);
}

sub master_security_group {
    my $self = shift;
    return unless $self->running_as_instance;
    return ($self->{instance_metadata}->securityGroups)[0];
}

sub master_ip {
    my $self = shift;
    my $ip   = $self->option('MASTER','external_ip');
    $ip ||= $self->_get_external_ip;
    return $ip;
}

sub initialize {
    my $self = shift;
    $self->_parse_conf_file;
    $self->_parse_instance_metadata;
}

sub running_as_instance {
    my $self = shift;
    return -e '/var/lib/cloud/data/previous-instance-id' 
	&& head('http://169.254.169.254');
}


#######################
# status
######################

# return true if slave is listening on at least one of the designated ports
sub ping_slave {
    my $self      = shift;
    my $instance  = shift;
    my $ip        = $instance->ipAddress;
    my ($port) = $self->slave_ports;
    return defined head("$ip:$port");
}

# returns list of slave instances as VM::EC2::Instance objects
sub running_slaves {
    my $self = shift;
    $self->{running_slaves} ||= {};
    return values %{$self->{running_slaves}};
}

sub add_slave {
    my $self = shift;
    my $instance = shift;
    $self->{running_slaves}{$instance}=$instance;
}

sub remove_slave {
    my $self = shift;
    my $instance = shift;
    delete $self->{running_slaves}{$instance};
}

# given an instance ID, returns the slave VM::EC2::Instance object
sub id2slave {
    my $self = shift;
    my $id   = shift;
    return $self->{running_slaves}{$id};
}

# spot requests - only tracks pending requests
sub pending_spot_requests {
    my $self = shift;
    $self->{pending_requests} ||= {};
    return values %{$self->{pending_requests}};
}

sub add_spot_request {
    my $self = shift;
    my $sr   = shift;
    $self->{pending_requests}{$sr} = $sr;
}

sub remove_spot_request {
    my $self = shift;
    my $sr   = shift;
    delete $self->{pending_requests}{$sr};
}

sub id2_spot_request {
    my $self = shift;
    my $id   = shift;
    return $self->{pending_requests}{$id};
}

# launch a spot instance request
sub request_spot_instance {
    my $self = shift;
    my $ec2  = $self->ec2;
    my $subnet = $self->slave_subnet;
    my @requests = $ec2->request_spot_instances(
	-image_id             => $self->slave_image_id,
	-instance_type        => $self->slave_instance_type,
	-instance_count       => 1,
	-security_group_id    => $self->slave_security_group,
	-spot_price           => $slave->spot_price,
	$subnet? (-subnet_id  => $subnet) : (),
	-user_data         => "#!/bin/sh\nexec /opt/gbrowse/etc/init.d/gbrowse-slave start",
	);
    @requests or croak $ec2->error_str;
    $_->add_tag(Requestor=>'GBrowse AWS Balancer') foreach @requests;
    $self->add_spot_request($_) foreach @requests;
}

sub kill_slave {
    my $self     = shift;
    my $instance = shift;
    $self->remove_slave($instance);
    $self->reconfigure_master();
    $instance->terminate();
}

sub update_requests {
    my $self = shift;
    my @requests = $self->pending_spot_requests;
    for my $sr (@requests) {
	my $state    = $sr->current_state;
	my $instance = $sr->instance;
	if ($state eq 'closed' && $instance && $instance->instanceState eq 'running') {
	    $instance->add_tag(Name => 'GBrowse Slave');
	    if ($self->ping_slave($instance)) {  # new running slave
		$self->add_slave($instance);
		$self->remove_spot_request($sr);
		$self->reconfigure_master();
	    }
	}
    }
}



#######################
# internal routines
######################

sub _get_external_ip {
    my $ip= get('http://icanhazip.com');
    chomp($ip);
    return $ip;
}

sub _parse_conf_file {
    my $self = shift;
    return if exists $self->{options}{'LOAD TABLE'};
    open my $f,$self->conf_file or croak "Could not open ",$self->conf_file,": $!";
    $self->{pushback} = [];
    while (defined(my $line = $self->_getline($f))) {
	$self->_parse_stanza($1,$f) if $line =~ /^\[([^]]+)\]/;
    }
    close $f;
    croak "invalid config file; must contain [LOAD TABLE] and [SLAVE] stanzas"
	unless exists $self->{options}{'LOAD TABLE'} and exists $self->{options}{'SLAVE'};
}

sub _parse_stanza {
    my $self = shift;
    my ($stanza,$fh) = @_;
    if (uc $stanza eq 'LOAD TABLE') {
	$self->_parse_load_table($fh);
    } else {
	$self->_parse_regular_stanza($stanza,$fh);
    }
}

sub _parse_load_table {
    my $self = shift;
    my $fh   = shift;
    while (my $line = $self->_get_stanza_line($fh)) {
	my @tokens = split /\s+/,$line;
	@tokens    == 3 or croak "invalid load table line: $line";
	my ($load,$min,$max) = @tokens;
	$self->{options}{'LOAD TABLE'}{$load} = [$min,$max];
    } 
}

sub _parse_regular_stanza {
    my $self = shift;
    my ($stanza,$fh) = @_;
    while (my $line = $self->_get_stanza_line($fh)) {
	my ($option,$value) = $line =~ /^(\S+)\s*=\s*(.+)/ or next;
	$self->{options}{uc $stanza}{$option} = $value;
    }
}

sub _get_stanza_line {
    my $self = shift;
    my $fh   = shift;
    my $line = $self->_getline($fh);
    if ($line =~ /^\[/) {
	push @{$self->{pushback}},$line;
	return;
    }
    return $line;
}

sub _getline {
    my $self = shift;
    my $fh   = shift;

    if (@{$self->{pushback}}) {
	return pop @{$self->{pushback}};
    }

    while (1) {
	my $line = <$fh> or return;
	chomp $line;
	$line =~ /^\s*#/ and next;
	$line =~ s/\s+#.*$//;
	$line =~ /\S/    or  next;
	return $line;
    }
}

sub _parse_instance_metadata {
    my $self = shift;
    $self->{instance_metadata} ||= VM::EC2::Instance::Metadata->new();
}

sub DESTROY {
    my $self = shift;
    if (my $sg = $self->{slave_security_group}) {
	$self->ec2->delete_security_group($sg);
    }
}

1;

=head1 AUTHOR

Lincoln Stein E<lt>lincoln.stein@gmail.comE<gt>.

Copyright (c) 2012 Ontario Institute for Cancer Research

This package and its accompanying libraries is free software; you can
redistribute it and/or modify it under the terms of the GPL (either
version 1, or at your option, any later version) or the Artistic
License 2.0.  Refer to LICENSE for the full license text. In addition,
please see DISCLAIMER.txt for disclaimers of warranty.

=cut
