package Net::Amazon::Glacier;

use 5.10.0;
use strict;
use warnings;
use feature 'say';

use Net::Amazon::Signature::V4;
use Net::Amazon::TreeHash;

use HTTP::Request;
use LWP::UserAgent;
use JSON::PP;
use POSIX qw/strftime/;
use Digest::SHA qw/sha256_hex/;
use File::Slurp;
use Carp;

=head1 NAME

Net::Amazon::Glacier - An implementation of the Amazon Glacier RESTful API.

=head1 VERSION

Version 0.13

=cut

our $VERSION = '0.13';

=head1 SYNOPSIS

This module implements the Amazon Glacier RESTful API, version 2012-06-01 (current at writing). It can be used to manage Glacier vaults and upload archives to them. Amazon Glacier is Amazon's long-term storage service.

Perhaps a little code snippet.

	use Net::Amazon::Glacier;

	my $glacier = Net::Amazon::Glacier->new(
		'eu-west-1',
		'AKIMYACCOUNTID',
		'MYSECRET',
	);
	
	my $vault = 'a_vault';
	my @vaults = $glacier->list_vaults();
	
	if ( $glacier->create_vault( $vault ) ) {

		if ( my $archive_id = $glacier->upload_archive( './archive.7z' ) ) {

			my $job_id = $glacier->inititate_job( $vault, $archive_id );
			
			# Jobs generally take about 4 hours to complete
			my $job_description = $glacier->describe_job( $vault, $job_id );
			
			# For a better way to wait for completion, see
			# http://docs.aws.amazon.com/amazonglacier/latest/dev/api-initiate-job-post.html
			while ( $job_description->{'StatusCode'} ne 'Succeeded' ) {
				sleep 15 * 60 * 60;
				$job_description = $glacier->describe_job( $vault, $job_id );
			}
			
			my $archive_bytes = $glacier->get_job_output( $vault, $job_id );
			
			# Jobs live as completed jobs for "a period", according to
			# http://docs.aws.amazon.com/amazonglacier/latest/dev/api-jobs-get.html
			my @jobs = $glacier->list_jobs( $vault );
			
			# As of 2013-02-09 jobs are blindly created even if a job for the same archive_id and Range exists.
			# Keep $archive_ids, reuse the expensive job resource, and remember 4 hours.
			foreach my $job ( @jobs ) {
				next unless $job->{ArchiveId} eq $archive_id;
				my $archive_bytes = $glacier->get_job_output( $vault, $job_id );
			}

		}
		
	}

The functions are intended to closely reflect Amazon's Glacier API. Please see Amazon's API reference for documentation of the functions: L<http://docs.amazonwebservices.com/amazonglacier/latest/dev/amazon-glacier-api.html>.

=head1 CONSTRUCTOR

=head2 new( $region, $access_key_id, $secret )

=cut

sub new {
	my $class = shift;
	my ( $region, $access_key_id, $secret ) = @_;
	my $self = {
		region => $region,
		ua     => LWP::UserAgent->new(),
		sig    => Net::Amazon::Signature::V4->new( $access_key_id, $secret, $region, 'glacier' ),
	};
	bless $self, $class;
}

=head1 VAULT OPERATORS

=head2 create_vault( $vault_name )

Creates a vault with the specified name. Returns true on success, false on failure.
L<Create Vault (PUT vault)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vault-put.html>
=cut

sub create_vault {
	my ( $self, $vault_name ) = @_;
	croak "no vault name given" unless $vault_name;
	my $res = $self->_send_receive( PUT => "/-/vaults/$vault_name" );
	return $res->is_success;
}

=head2 delete_vault( $vault_name )

Deletes the specified vault. Returns true on success, false on failure.
L<Delete Vault (DELETE vault)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vault-delete.html>
=cut

sub delete_vault {
	my ( $self, $vault_name ) = @_;
	croak "no vault name given" unless $vault_name;
	my $res = $self->_send_receive( DELETE => "/-/vaults/$vault_name" );
	return $res->is_success;
}

=head2 describe_vault( $vault_name )

Fetches information about the specified vault. Returns a hash reference with the keys described by L<http://docs.amazonwebservices.com/amazonglacier/latest/dev/api-vault-get.html>. Returns false on failure.
L<Describe Vault (GET vault)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vault-get.html>

=cut

sub describe_vault {
	my ( $self, $vault_name ) = @_;
	croak "no vault name given" unless $vault_name;
	my $res = $self->_send_receive( GET => "/-/vaults/$vault_name" );
	return $self->_decode_and_handle_response( $res );
}

=head2 list_vaults

Lists the vaults. Returns an array with all vaults.
L<Amazon Glacier List Vaults (GET vaults)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vaults-get.html>.

A call to list_vaults can result in many calls to the the Amazon API at a rate of 1 per 1,000 vaults in existence.
Calls to List Vaults in the API are L<free|http://aws.amazon.com/glacier/pricing/#storagePricing>.

=cut

sub list_vaults {
	my ( $self ) = @_;
	my @vaults;
	my $marker;
	do {
		#1000 is the default limit, send a marker if needed
		my $res = $self->_send_receive( GET => "/-/vaults?limit=1000" . $marker?'&'.$marker:'');
		my $decoded = $self->_decode_and_handle_response( $res );

		push @vaults, @{$decoded->{VaultList}};
		$marker = $decoded->{Marker};
	} while ( $marker );
	return ( \@vaults );
}

=head2 set_vault_notifications( $vault_name, $sns_topic, $events )

Sets vault notifications for a given vault.
An SNS Topic to send notifications to must be provided. The SNS Topic must grant permission to the vault to be allowed to publish notifications to the topic.
An array ref to a list of events must be provided. Valid events are ArchiveRetrievalCompleted and InventoryRetrievalCompleted
upon job completion may also be supplied.
Return true on success, false otherwise.
L<Set Vault Notification Configuration (PUT notification-configuration)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vault-notifications-put.html>.

=cut

sub set_vault_notifications {
	my ( $self, $vault_name, $sns_topic, $events ) = @_;
	croak "no vault name given" unless $vault_name;
	croak "no sns topic given" unless $sns_topic;
	croak "events should be an array ref" unless ref $events eq 'ARRAY';
	
	my $content_raw;
	
	$content_raw->{SNSTopic} = $sns_topic
		if defined($sns_topic);
	
	$content_raw->{Events} = $events
		if defined($events);
	
	my $res = $self->_send_receive(
		PUT => "/-/vaults/$vault_name/notification-configuration",
		[
		],
		encode_json($content_raw),
	);
	return $res->is_success;
}

=head2 get_vault_notifications( $vault_name )

Gets vault notifications status for a given vault.
Return false on failure or a hash with an 'SNSTopic' and and array of 'Events' on success.
L<Get Vault Notifications (GET notification-configuration)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vault-notifications-get.html>.

=cut

sub get_vault_notifications {
	my ( $self, $vault_name, $sns_topic, $events ) = @_;
	croak "no vault name given" unless $vault_name;
	
	my $res = $self->_send_receive(
		PUT => "/-/vaults/$vault_name/notification-configuration",
	);
	return 0 unless $res->is_success;
	return $self->_decode_and_handle_response( $res );
}

=head2 delete_vault_notifications( $vault_name )

Deletes vault notifications for a given vault.
Return true on success, false otherwise.
L<Delete Vault Notifications (DELETE notification-configuration)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-vault-notifications-delete.html>.

=cut

sub delete_vault_notifications {
	my ( $self, $vault_name, $sns_topic, $events ) = @_;
	croak "no vault name given" unless $vault_name;
	
	my $res = $self->_send_receive(
		DELETE => "/-/vaults/$vault_name/notification-configuration",
	);
	return $res->is_success;
}

=head1 ARCHIVE OPERATIONS

=head2 upload_archive( $vault_name, $archive_path, [ $description ] )

Uploads an archive to the specified vault. $archive_path is the local path to any file smaller than 4GB. For larger files, see multi-part upload. An archive description of up to 1024 printable ASCII characters can be supplied. Returns the Amazon-generated archive ID on success, or false on failure.
L<Upload Archive (POST archive)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-archive-post.html>

=cut

sub upload_archive {
	my ( $self, $vault_name, $archive_path, $description ) = @_;
	croak "no vault name given" unless $vault_name;
	croak "no archive path given" unless $archive_path;
	croak 'archive path is not a file' unless -f $archive_path;
	$description //= '';
	my $content = read_file( $archive_path );

	my $th = Net::Amazon::TreeHash->new();
	open( my $content_fh, '<', $archive_path ) or croak $!;
	$th->eat_file( $content_fh );
	close $content_fh;
	$th->calc_tree;

	my $res = $self->_send_receive(
		POST => "/-/vaults/$vault_name/archives",
		[
			'x-amz-archive-description' => $description,
			'x-amz-sha256-tree-hash' => $th->get_final_hash(),
			'x-amz-content-sha256' => sha256_hex( $content ),
		],
		$content
	);
	return 0 unless $res->is_success;
	if ( $res->header('location') =~ m{^/([^/]+)/vaults/([^/]+)/archives/(.*)$} ) {
		my ( $rec_uid, $rec_vault_name, $rec_archive_id ) = ( $1, $2, $3 );
		return $rec_archive_id;
	} else {
		carp 'request succeeded, but reported archive location does not match regex: ' . $res->header('location');
		return 0;
	}
}

=head2 delete_archive( $vault_name, $archive_id )

Issues a request to delete a file from Glacier. $archive_id is the ID you received either when you uploaded the file originally or from an inventory.
L<Delete Archive (DELETE archive)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-archive-delete.html>

=cut

sub delete_archive {
	my ( $self, $vault_name, $archive_id ) = @_;
	croak "no vault name given" unless $vault_name;
	croak "no archive ID given" unless $archive_id;
	my $res = $self->_send_receive( DELETE => "/-/vaults/$vault_name/archives/$archive_id" );
	return $res->is_success;
}

=head1 JOB OPERATIONS

=head2 initiate_archive_retrieval( $vault_name, $archive_id, [
$description, $sns_topic ] )

Initiates an archive retrieval job. $archive_id is an ID previously
retrieved from Amazon Glacier. A job description of up to 1,024 printable
ASCII characters may be supplied. An SNS Topic to send notifications to
upon job completion may also be supplied.
L<Initiate a Job (POST jobs)|docs.aws.amazon.com/amazonglacier/latest/dev/api-initiate-job-post.html#api-initiate-job-post-requests-syntax>.

=cut

sub initiate_archive_retrieval {
	my ( $self, $vault_name, $archive_id, $description, $sns_topic ) = @_;
	croak "no vault name given" unless $vault_name;
	croak "no archive id given" unless $archive_id;

	my $content_raw = {
		Type => 'archive-retrieval',
		ArchiveId => $archive_id,
	};

	$content_raw->{Description} = $description
		if defined($description);

	$content_raw->{SNSTopic} = $sns_topic
		if defined($sns_topic);

	my $res = $self->_send_receive(
		POST => "/-/vaults/$vault_name/jobs",
		[ ],
		encode_json($content_raw),
	);

	return 0 unless $res->is_success;
	return $res->header('x-amz-job-id');
}

=head2 initiate_inventory_retrieval( $vault_name, [ $format, $description,
$sns_topic ] )

Initiates an inventory retrieval job. $format is either CSV or JSON (default).
A job description of up to 1,024 printable ASCII characters may be supplied. An
SNS Topic to send notifications to upon job completion may also be supplied.
L<Initiate a Job (POST jobs)|docs.aws.amazon.com/amazonglacier/latest/dev/api-initiate-job-post.html#api-initiate-job-post-requests-syntax>.

=cut

sub initiate_inventory_retrieval {
	my ( $self, $vault_name, $format, $description, $sns_topic ) = @_;
	croak "no vault name given" unless $vault_name;

	my $content_raw = {
		Type => 'inventory-retrieval',
	};

	$content_raw->{Format} = $format
		if defined($format);

	$content_raw->{Description} = $description
		if defined($description);

	$content_raw->{SNSTopic} = $sns_topic
		if defined($sns_topic);

	my $res = $self->_send_receive(
		POST => "/-/vaults/$vault_name/jobs",
		[ ],
		encode_json($content_raw),
	);

	return 0 unless $res->is_success;
	return $res->header('x-amz-job-id');
}

=head2 initiate_job( ( $vault_name, $archive_id, [
$description, $sns_topic ] )

Effectively calls initiate_inventory_retrieval.
Exists for the sole purpose or implementing the Amazon Glacier Developer Guide (API Version 2012-06-01)
nomenclature.
L<Initiate a Job (POST jobs)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-initiate-job-post.html>.

=cut

sub initiate_job {
	initiate_inventory_retrieval( @_ );
}

=head2 describe_job( $vault_name, $job_id )

Retrieves a hashref with information about the requested JobID.
L<Amazon Glacier Describe Job (GET JobID)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-describe-job-get.html>.

=cut

sub describe_job {
	my ( $self, $vault_name, $job_id ) = @_;
	my $res = $self->_send_receive( GET => "/-/vaults/$vault_name/jobs/$job_id" );
	return $self->_decode_and_handle_response( $res );
}

=head2 get_job_output( $vault_name, $job_id, [ $range ] )

Retrieves the output of a job, returns a binary blob. Optional range
parameter is passed as an HTTP header.
L<Amazon Glacier Get Job Output (GET output)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-job-output-get.html>.

=cut

sub get_job_output {
	my ( $self, $vault_name, $job_id, $range ) = @_;

	my $headers = [];

	push @$headers, (Range => $range)
		if defined($range);

	my $res = $self->_send_receive( GET => "/-/vaults/$vault_name/jobs/$job_id/output", $headers );
	if ( $res->is_success ) {
		return $res->decoded_content;
	} else {
		return undef;
	}
}

=head2 list_jobs( $vault_name )

Return an array with information about all recently completed jobs for the specified vault.
L<Amazon Glacier List Jobs (GET jobs)|http://docs.aws.amazon.com/amazonglacier/latest/dev/api-jobs-get.html>.

A call to list_jobs can result in many calls to the the Amazon API at a rate of 1 per 1,000 recently completed job in existence.
Calls to List Jobs in the API are L<free|http://aws.amazon.com/glacier/pricing/#storagePricing>.

=cut

sub list_jobs {
	my ( $self, $vault_name ) = @_;
	my @completed_jobs;
	my $marker;
	do {
		#1000 is the default limit, send a marker if needed
		my $res = $self->_send_receive( GET => "/-/vaults/$vault_name/jobs?limit=1000" . $marker?'&'.$marker:'' );
		my $decoded = $self->_decode_and_handle_response( $res );
		
		push @completed_jobs, @{$decoded->{JobList}};
		$marker = $decoded->{Marker};
	} while ( $marker );
	return ( \@completed_jobs );
}

# helper functions

sub _decode_and_handle_response {
	my ( $self, $res ) = @_;
	if ( $res->is_success ) {
		return decode_json( $res->decoded_content );
	} else {
		return undef;
	}
}

sub _send_receive {
	my $self = shift;
	my $req = $self->_craft_request( @_ );
	return $self->_send_request( $req );
}

sub _craft_request {
	my ( $self, $method, $url, $header, $content ) = @_;
	my $host = 'glacier.'.$self->{region}.'.amazonaws.com';
	my $total_header = [
		'x-amz-glacier-version' => '2012-06-01',
		'Host' => $host,
		'Date' => strftime( '%Y%m%dT%H%M%SZ', gmtime ),
		$header ? @$header : ()
	];
	my $req = HTTP::Request->new( $method => "https://$host$url", $total_header, $content);
	my $signed_req = $self->{sig}->sign( $req );
	return $signed_req;
}

sub _send_request {
	my ( $self, $req ) = @_;
	my $res = $self->{ua}->request( $req );
	if ( $res->is_error ) {
		my $error = decode_json( $res->decoded_content );
		carp sprintf 'Non-successful response: %s (%s)', $res->status_line, $error->{code};
		carp decode_json( $res->decoded_content )->{message};
	}
	return $res;
}

=head1 NOT IMPLEMENTED

The following parts of Amazon's API have not yet been implemented. This is mainly because the author hasn't had a use for them yet. If you do implement them, feel free to send a patch.

=over 4

=item * Multipart upload operations

=back

=head1 SEE ALSO

See also Victor Efimov's MT::AWS::Glacier, an application for AWS Glacier synchronization. It is available at L<https://github.com/vsespb/mt-aws-glacier>.

=head1 AUTHORS

Maintained and originally written by Tim Nordenfur, C<< <tim at gurka.se> >>. Support for job operations was contributed by Ted Reed at IMVU. Support for many operations was contributed by Gonzalo Barco.

=head1 BUGS

Please report any bugs or feature requests to C<bug-net-amazon-glacier at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-Amazon-Glacier>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::Amazon::Glacier


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-Amazon-Glacier>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-Amazon-Glacier>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-Amazon-Glacier>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-Amazon-Glacier/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2012 Tim Nordenfur.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of Net::Amazon::Glacier
