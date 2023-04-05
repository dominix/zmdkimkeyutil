#!/usr/bin/perl
#
# ***** BEGIN LICENSE BLOCK *****
# Zimbra Collaboration Suite Server
# Copyright (C) 2012, 2013, 2014, 2015, 2016 Synacor, Inc.
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software Foundation,
# version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with this program.
# If not, see <https://www.gnu.org/licenses/>.
# ***** END LICENSE BLOCK *****
#
# to import a key, do a zmdkimkeyutil -q -d domain.ex on original server
# put key in /tmp/privkey, put publickey in /tmp/public and note selector
# zmdkimkeyutil -i -d domain.ex  -s <selector> -k /tmp/privkey -p /tmp/public
use strict;
use lib '/opt/zimbra/common/lib/perl5';
use Net::LDAP;
use Net::LDAP::Util qw ( ldap_error_name );
use XML::Simple;
use Getopt::Long qw(:config no_ignore_case);
use Data::UUID;

if ( ! -x "/opt/zimbra/common/sbin/opendkim" ) {
  print "ERROR: opendkim does not appear to be installed - exiting\n";
  exit(1);
}

my $id = getpwuid($<);
chomp $id;
if ($id ne "zimbra") {
  print STDERR "Error: must be run as zimbra user\n";
  exit (1);
}

my ($add, $help, $query, $update, $domain, $delete, $selector, $subdomain, $import, $privkey, $pubkey);
my $bits=2048;

my $opts_good = GetOptions(
        'h|help' => \$help,
        'a|add' => \$add,
        'b|bits=s' => \$bits,
        'd|domain=s' => \$domain,
        'q|query' => \$query,
        'i|import' => \$import,
        'r|remove' => \$delete,
        's|selector=s' => \$selector,
        'S|subdomains' => \$subdomain,
        'u|update' => \$update,
        'k|privkey=s' => \$privkey,
        'p|pubkey=s' => \$pubkey,
);

if (!$opts_good) {
  print STDERR "\n";
  usage();
}
if ($help) {
  usage(0);
}

if (!($domain) && !($query)) {
  usage(0);
}

if ($query && !($selector) && !($domain)) {
  usage(0);
}

if (!($add) && !($query) && !($update) && !($delete) && !($import)) {
  usage(0);
}

if ($add+$query+$update+$delete+$import > 1) {
  usage(0);
}

my $localxml = XMLin("/opt/zimbra/conf/localconfig.xml");
my $ldap_master_url = $localxml->{key}->{ldap_master_url}->{value};
my $zimbra_admin_dn = $localxml->{key}->{zimbra_ldap_userdn}->{value};
my $zimbra_admin_password = $localxml->{key}->{zimbra_ldap_password}->{value};
chomp($zimbra_admin_password);
my $ldap_starttls_supported = $localxml->{key}->{ldap_starttls_supported}->{value};
my $zimbra_require_interprocess_security = $localxml->{key}->{zimbra_require_interprocess_security}->{value};

my $keygen = "/opt/zimbra/common/sbin/opendkim-genkey";

my $mesg;
my @masters=split(/ /, $ldap_master_url);
my $master_ref=\@masters;
my $ldap = Net::LDAP->new($master_ref) or die "$@";

if ($ldap_master_url !~ /^ldaps/i) {
  if ($ldap_starttls_supported) {
    $mesg = $ldap->start_tls(
        verify => 'none',
        capath => "/opt/zimbra/conf/ca",
     ) or die "start_tls: $@";
     $mesg->code && die "Could not execute StartTLS\n";
  }
}
if (!defined($ldap)) {
  die "Server down\n";
}
$mesg = $ldap->bind($zimbra_admin_dn, password=>$zimbra_admin_password);
$mesg->code && die "Bind: ". $mesg->error . "\n";

if ($domain) {
  $mesg = $ldap ->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain))",
      scope=>"sub",
  );
  
  my $size = $mesg->count;
  if ($size == 0) {
    print "Domain $domain not found.\n";
    exit(1);
  }
}

if($add) {
  $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain)(DKIMSelector=*))",
      scope=>"sub",
  );
  my $size = $mesg->count;
  if ($size > 0) {
    print "Error: Domain $domain already has DKIM enabled.\n";
    exit(1);
  }
  $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain))",
      scope=>"sub",
  );
  my $entry = $mesg->entry($size-1);
  my $dn = $entry->dn;
  if (!($selector)) {
    my $ug = Data::UUID->new;
    $selector = $ug->create_str();
  }
  my $subflag="";
  if ($subdomain) {
    $subflag="--nosubdomains";
  }
  if ($bits < 2048) {
   print "Bit size less than 2048 is not allowed, as it is insecure.\n";
  } else {
    qx($keygen $subflag -b $bits -s $selector -d $domain -D /opt/zimbra/data/tmp);
  }
  my $privatekey = "/opt/zimbra/data/tmp/${selector}.private";
  my $publickey = "/opt/zimbra/data/tmp/${selector}.txt";
  if (-f $privatekey && -s $privatekey && -f $publickey && -s $publickey) {
    my $private;
    my $public;
    {
      local $/ = undef; # Slurp mode
      open PRIVATEKEY, "$privatekey" or die "Cannot open $privatekey for read :$!";
      $private = <PRIVATEKEY>;
      close PRIVATEKEY;
      open PUBLICKEY, "$publickey" or die "Cannot open $publickey for read :$!";
      $public = <PUBLICKEY>;
      close PUBLICKEY;
    }
    $mesg = $ldap->modify( $dn,
      add => [
        objectClass   => 'DKIM',    # Add description attribute
        DKIMSelector  => "$selector",
        DKIMDomain    => "$domain",
        DKIMKey       => "$private",
        DKIMPublicKey => "$public",
        DKIMIdentity  => "$domain",
      ]
    );
    if ($mesg->code) {
      my $error_name = $mesg->error_name;
      if ($error_name eq 'LDAP_CONSTRAINT_VIOLATION') {
        print "Error: Failed to update LDAP: Selector $selector is already in use.\n";
      } else {
        print "Error: Failed to update LDAP: " . ldap_error_name($mesg->code) ."\n";
      }
      exit 1;
    } else {
      print "DKIM Data added to LDAP for domain $domain with selector $selector\n";
    }
    unlink($privatekey);
    unlink($publickey);
    $ldap->unbind;
    print "Public signature to enter into DNS:\n";
    print "$public";
    exit 0;
  } else {
    print "Error: Key generation failed.\n";
    exit 1;
  }
} elsif ($query) {
  if (!($selector)) {
    $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain)(DKIMSelector=*))",
      scope=>"sub",
    );
  } else {
    $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(DKIMSelector=$selector))",
      scope=>"sub",
    );
  }
  my $size = $mesg->count;
  if ($size == 0) {
    if (!($selector)) {
      print "No DKIM Information for domain $domain\n";
      $ldap->unbind;
      exit(1);
    } else {
      print "No DKIM Information for Selector $selector\n";
      $ldap->unbind;
      exit(1);
    }
  } else {
    my $entry=$mesg->entry($size-1);
    my $attrval=$entry->get_value("DKIMDomain");
    print "DKIM Domain:\n$attrval\n\n";
    my $attrval=$entry->get_value("DKIMSelector");
    print "DKIM Selector:\n$attrval\n\n";
    my $attrval=$entry->get_value("DKIMKey");
    print "DKIM Private Key:\n$attrval\n";
    my $attrval=$entry->get_value("DKIMPublicKey");
    print "DKIM Public signature:\n$attrval\n";
    my $attrval=$entry->get_value("DKIMIdentity");
    print "DKIM Identity:\n$attrval\n\n";
  }
  $ldap->unbind;
  exit 0;
} elsif ($update) {
  $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain)(DKIMSelector=*))",
      scope=>"sub",
  );
  my $size = $mesg->count;
  if ($size == 0 ) {
    print "Error: Domain $domain doesn't have DKIM enabled.\n";
    exit(1);
  }
  my $entry = $mesg->entry($size-1);
  my $dn = $entry->dn;
  if (!($selector)) {
    my $ug = Data::UUID->new;
    $selector = $ug->create_str();
  }
  my $subflag="";
  if ($subdomain) {
    $subflag="--nosubdomains";
  }
  if ($bits < 2048) {
    print "Bit size less than 2048 is not allowed, as it is insecure.\n";
  } else {
    qx($keygen $subflag -b $bits -s $selector -d $domain -D /opt/zimbra/data/tmp);
  }
  my $privatekey = "/opt/zimbra/data/tmp/${selector}.private";
  my $publickey = "/opt/zimbra/data/tmp/${selector}.txt";
  if (-f $privatekey && -s $privatekey && -f $publickey && -s $publickey) {
    my $private;
    my $public;
    {
      local $/ = undef; # Slurp mode
      open PRIVATEKEY, "$privatekey" or die "Cannot open $privatekey for read :$!";
      $private = <PRIVATEKEY>;
      close PRIVATEKEY;
      open PUBLICKEY, "$publickey" or die "Cannot open $publickey for read :$!";
      $public = <PUBLICKEY>;
      close PUBLICKEY;
    }
    $mesg = $ldap->modify( $dn,
      replace => [
        DKIMSelector  => "$selector",
        DKIMKey       =>  "$private",
        DKIMPublicKey => "$public",
      ]
    );
    if ($mesg->code) {
      my $error_name = $mesg->error_name;
      if ($error_name eq 'LDAP_CONSTRAINT_VIOLATION') {
        print "Error: Failed to update LDAP: Selector $selector is already in use.\n";
      } else {
        print "Error: Failed to update LDAP: " . ldap_error_name($mesg->code) ."\n";
      }
      exit 1;
    } else {
      print "DKIM Data added to LDAP for domain $domain with selector $selector\n";
    }
    unlink($privatekey);
    unlink($publickey);
    $ldap->unbind;
    print "Public signature to enter into DNS:\n";
    print "$public";
    exit 0;
  } else {
    print "Error: Key generation failed.\n";
    $ldap->unbind;
    exit 1;
  }
} elsif ($delete) {
  $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain)(DKIMSelector=*))",
      scope=>"sub",
  );
  my $size = $mesg->count;
  if ($size == 0 ) {
    print "Error: Domain $domain doesn't have DKIM enabled.\n";
    $ldap->unbind;
    exit(1);
  }
  my $entry = $mesg->entry($size-1);
  my $dn = $entry->dn;
  $mesg = $ldap->modify ( $dn,
    delete => {
      objectClass   => 'DKIM',
      DKIMDomain    => [],
      DKIMKey       => [],
      DKIMIdentity  => [],
      DKIMPublicKey => [],
      DKIMSelector  => [],
    }
  );
  if ($mesg->code) {
    $ldap->unbind;
    print "Error: Failed to delete data from LDAP: " . ldap_error_name($mesg->code) ."\n";
    exit 1;
  } else {
    print "DKIM Data deleted in LDAP for domain $domain\n";
    $ldap->unbind;
  }
} elsif ($import) {
  $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain)(DKIMSelector=*))",
      scope=>"sub",
  );
  my $size = $mesg->count;
  if ($size > 0) {
    print "Error: Domain $domain already has DKIM enabled.\n";
    exit(1);
  }
  $mesg = $ldap->search(
      base=>"",
      filter=>"(&(objectClass=zimbraDomain)(zimbraDomainName=$domain))",
      scope=>"sub",
  );
  my $entry = $mesg->entry($size-1);
  my $dn = $entry->dn;
  if (!($selector)) {
    print "Error: need selector.\n";
    exit(1);
  }
  my $subflag="";
  if ($subdomain) {
    $subflag="--nosubdomains";
  }
  if ($bits < 2048) {
   print "Bit size less than 2048 is not allowed, as it is insecure.\n";
   exit(1);
  } 
  my $private;
  my $public;
    {
      local $/ = undef; # Slurp mode
      open PRIVATEKEY, "$privkey" or die "Cannot open $privkey for read :$!";
      $private = <PRIVATEKEY>;
      close PRIVATEKEY;
      open PUBLICKEY, "$pubkey" or die "Cannot open $pubkey for read :$!";
      $public = <PUBLICKEY>;
      close PUBLICKEY;
    }
  $mesg = $ldap->modify( $dn,
      add => [
        objectClass   => 'DKIM',    # Add description attribute
        DKIMSelector  => "$selector",
        DKIMDomain    => "$domain",
        DKIMKey       => "$private",
        DKIMPublicKey => "$public",
        DKIMIdentity  => "$domain",
      ]
    );
  if ($mesg->code) {
      my $error_name = $mesg->error_name;
      if ($error_name eq 'LDAP_CONSTRAINT_VIOLATION') {
        print "Error: Failed to update LDAP: Selector $selector is already in use.\n";
      } else {
        print "Error: Failed to update LDAP: " . ldap_error_name($mesg->code) ."\n";
      }
      exit 1;
  } else {
      print "DKIM Data added to LDAP for domain $domain with selector $selector\n";
  }
    $ldap->unbind;
    exit 0;
} else {
  print "Unknown command";
  $ldap->unbind;
  exit 1;
}

$ldap->unbind();
exit;

sub usage() {
  print "Usage: $0 [-a [-b]] [-q] [-r] [-s selector] [-S] [-u [-b]] [-d domain]\n";
  print "-a: Add new key pair and selector for domain\n";
  print "-b: Optional parameter specifying the number of bits for the new key.\n";
  print "    Only works with -a and -u.  Default when not specified is 2048 bits.\n";
  print "-d domain: Domain to use\n";
  print "-h: Show this usage block\n";
  print "-q: Query DKIM information for domain\n";
  print "-r: Remove DKIM keys for domain\n";
  print "-s: Use custom selector string instead of random UUID\n";
  print "-S: Generate keys with subdomain data.  This must be used if you want to sign both example.com and sub.example.com separately.\n";
  print "    Only works with -a and -u.  Default is not to set this flag.\n";
  print "-u: Update keys for domain\n";
  print "-i: import keys -s selector -k privkey -p pubkey -d domain\n";
  print "One of [a, q, r, or u] must be supplied\n";
  print "For -q, search can be either by selector or domain\n";
  print "For all other usage patterns, domain is required\n";
  exit 1;
}
