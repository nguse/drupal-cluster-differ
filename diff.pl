#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use feature ':5.10';
use Mojo::UserAgent;
use Mojo::IOLoop;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use Text::Diff;
use Data::Dumper;
use Data::TreeDumper;
use Time::HiRes ('sleep');

my %results = ();
my (@errors, @mismatches) = ();

# ----------- Configure -----------

# Quiet
my $quiet = 1;
my $show_diff = 1;

# Limit parallel requests
my $max_conn = 50;

# Request timeout period
my $connection_timeout = 10;

# Limit spider depth
my $max_depth = 2;

# Backends to make the http requests against
my @backends = (
	"varnish1.foo.com",
	"varnish2.foo.com",
	"drupal1.foo.com",
	"drupal2.foo.com",
);

my @starting_urls = (
	'http://www.foo.com',
);

# URL matcher; if the URL does not match this regex, it will never be spidered
my $url_matcher = '^https?:\/\/www\.foo\.com';

# Normalize content
# Strip any elements from the response which is expected to differ between identical requests
sub normalize_content {
	my ($mojo) = @_;

	# Some filtering is required for Drupal

	# form build id ------------------------------------------------------------
	foreach my $node ($mojo->res->dom->find('[name=form_build_id]')->each) {
		# say $node;
		delete $node->{value};
	}

	# Unique class name Drupal generates view-dom-id-<id> --------------------
	foreach my $node ($mojo->res->dom->find('div.view')->each) {
		# say '------------------------';
		# say $node->attr('class');
		my $class = $node->attr('class');
		$class =~ s/ view\-dom\-id\-[a-f0-9]+//;
		$node->attr('class', $class);
		# say $node->attr('class');
	}

	# Drupal seems to screw up even/odd once in a while --------------------
	foreach my $node ($mojo->res->dom->find('.even')->each) {
		# say '------------------------';
		# say $node->attr('class');
		my $class = $node->attr('class');
		$class =~ s/ even / /;
		$node->attr('class', $class);
		# say $node->attr('class');
	}

	# Drupal seems to screw up even/odd once in a while --------------------
	foreach my $node ($mojo->res->dom->find('.odd')->each) {
		# say '------------------------';
		# say $node->attr('class');
		my $class = $node->attr('class');
		$class =~ s/ odd / /;
		$node->attr('class', $class);
		# say $node->attr('class');
	}

	my $content = Encode::encode_utf8($mojo->res->dom->content);

	# Theme Token ------------------------------------------------------------
	$content =~ s/"theme_token":"[a-zA-Z0-9\-_]+"//;

	return $content;
}

# Find the URLs we want to spider through
sub get_urls {
	my ($mojo) = @_;

	my @urls = ();

	foreach my $node ($mojo->res->dom->find('a[href]')->each) {
		my $url = Mojo::URL->new($node->attr('href'));
		# say $url;

		if (!$url->is_abs) {
			$url
				->base($mojo->req->url)
				->host($mojo->req->content->headers->host)
			;
		}

		$url = $url->to_abs->to_string;

		# Remove anchor portion of the URL
		$url =~ s/#.*//;
		# say $url;

		if ($url =~ /$url_matcher/) {
			# say 'matched -----------------------'
			push @urls, $url;
		}
	}

	foreach my $node ($mojo->res->dom->find('link[href]')->each) {
		my $url = Mojo::URL->new($node->attr('href'));
		# say $url;

		if (!$url->is_abs) {
			$url
				->base($mojo->req->url)
				->host($mojo->req->content->headers->host)
			;
		}

		$url = $url->to_abs->to_string;

		# Remove anchor portion of the URL
		$url =~ s/#.*//;
		# say $url;

		if ($url =~ /$url_matcher/) {
			# say 'matched -----------------------'
			push @urls, $url;
		}
	}

	return @urls;
}

# ----------- Run -----------

# Disable line buffering
# $| = 1;

# FIFO queue
my @queue = ();

# This tracks any URL that has been queued in the past so we only queue it once
my %queued_urls = ();

# Keep track of active connections
my $active = 0;

my $ua = Mojo::UserAgent->new;

# Ignore all cookies
$ua->cookie_jar->ignore(sub { 1 });

$ua = $ua->max_connections(10);
$ua = $ua->max_redirects(0);
$ua = $ua->request_timeout($connection_timeout);

# Iterate over each starting URL and add to the queue
foreach my $url (@starting_urls) {
	push @queue, {
		url 		=> $url,
		backend 	=> $backends[0],
		callback 	=> 'main_request_callback',
		level		=> 0,
	};

	$queued_urls{get_req_hash('GET', $url)} = 1;
}

# Callback for backend[0]
# This callback will trigger a crawl of the URLs on the page
# This will also trigger a request to each backend to compare the results
sub main_request_callback {
	my ($ua, $mojo) = @_;

	# say '--$active!';

	--$active;

	unless ($mojo->success) {
		push @errors, 'Error: ' . $mojo->res->error->{message} . ' ' . $mojo->req->url;
		say STDERR 'Error: ' . $mojo->res->error->{message} . ' ' . $mojo->req->url;
		# say STDERR DumpTree($mojo);
		return;
	}

	# Replace the host in the URL with the Host sent in the header for clarity
	my $backend = $mojo->req->url->host;
	my $host = $mojo->req->content->headers->host;
	my $current_level = $mojo->req->content->headers->referrer;
	$mojo->req->url->host($mojo->req->content->headers->host);

	if (
			$mojo->res->code != 200 &&
			$mojo->res->code != 301 &&
			$mojo->res->code != 302
	) {
		push @errors, sprintf('%s at %s; backend: %s', $mojo->res->code, $mojo->req->url->to_string, $host);
		say STDERR sprintf('%s at %s; backend: %s', $mojo->res->code, $mojo->req->url->to_string, $host);
		return;
	}

	store_results($ua, $mojo, $backend);

	# Make a new request for each backend
	foreach my $backend_host (@backends[1 .. $#backends]) {
		# say 'Request to another backend ' . $mojo->req->url->to_string . ' ' . $backend_host;
		push @queue, {
			url 		=> $mojo->req->url->to_string,
			backend 	=> $backend_host,
			callback 	=> 'sub_request_callback',
			level 		=> $current_level,
		};
	}

	# Don't try to fetch URLs if we've reached our maximum recursion depth
	return if $current_level >= $max_depth;

	# Don't try to fetch URLs from pages that are not text/html
	return if $mojo->res->headers->content_type !~ /^text\/html.*/;

	# Now do recursion and fetch pages linked to from this page
	foreach my $url (get_urls($mojo)) {
		# Check if we already queued this page
		my $key = get_req_hash('GET', $url);

		if ($queued_urls{$key}) {
			# say sprintf('%s: Already queued this page; skipping.', $url);
			next;
		}

		# say 'Queuing ' . $url . ' for backend[0]';

		push @queue, {
			url 		=> $url,
			backend 	=> $backends[0],
			callback 	=> 'main_request_callback',
			level 		=> $current_level + 1,
		};

		$queued_urls{get_req_hash('GET', $url)} = 1;
	}

	return;
}

# Call back for each backend other than backend[0]
# This call back will compare the results to the other backend
sub sub_request_callback {
	my ($ua, $mojo) = @_;

	# say '--$active!';

	--$active;

	unless ($mojo->success) {
		push @errors, 'Error: ' . $mojo->res->error->{message} . ' ' . $mojo->req->url;
		say STDERR 'Error: ' . $mojo->res->error->{message} . ' ' . $mojo->req->url;
		# say STDERR DumpTree($mojo);
		return;
	}

	# Replace the host in the URL with the Host sent in the header for clarity
	my $backend = $mojo->req->url->host;
	my $host = $mojo->req->content->headers->host;
	$mojo->req->url->host($mojo->req->content->headers->host);

	if (
			$mojo->res->code != 200 &&
			$mojo->res->code != 301 &&
			$mojo->res->code != 302
	) {
		push @errors, sprintf('%s at %s', $mojo->res->code, $mojo->req->url->to_string);
		say STDERR sprintf('%s at %s', $mojo->res->code, $mojo->req->url->to_string);
		return;
	}

	store_results($ua, $mojo, $backend);

	my $key = get_req_hash($mojo->req->method, $mojo->req->url->to_string);

	# Compare the results
	if ($mojo->res->code == 301 or $mojo->res->code == 302) {
		if (
			$results{$backend}{$key}{'code'} != $results{$backends[0]}{$key}{'code'}
			or
			$results{$backend}{$key}{'location'} ne $results{$backends[0]}{$key}{'location'}
		) {
			push @mismatches, sprintf('Mismatch at %s, backend: %s', $mojo->req->url->to_string, $backend);
			say STDERR sprintf('Mismatch at %s, backend: %s', $mojo->req->url->to_string, $backend);
			say STDERR '- ' . $results{$backends[0]}{$key}{'code'} . ' ' . $results{$backends[0]}{$key}{'location'};
			say STDERR '+ ' . $results{$backend}{$key}{'code'} . ' ' . $results{$backend}{$key}{'location'};
		}
	} else {
		if ($results{$backend}{$key}{'hash'} ne $results{$backends[0]}{$key}{'hash'}) {
			my $diff = diff(\$results{$backends[0]}{$key}{'content'} => \$results{$backend}{$key}{'content'});

			push @mismatches, sprintf('Mismatch at %s, backend: %s', $mojo->req->url->to_string, $backend);
			say STDERR sprintf('Mismatch at %s, backend: %s', $mojo->req->url->to_string, $backend);

			if ($show_diff) {
				say STDERR $diff;
			}
		}
	}

	# Delete the stored content for the non-primary backends after we are done with it (possible diff)
	delete $results{$backend}{$key}{'content'};
}

# Store the results
sub store_results {
	my ($ua, $mojo, $backend) = @_;

	# say sprintf('Storing %s for %s', $mojo->req->url->to_string, $backend);

	my $key = get_req_hash($mojo->req->method, $mojo->req->url->to_string);

	# Handle redirects
	if ($mojo->res->code == 301 or $mojo->res->code == 302) {
		my $location = $mojo->res->headers->location;

		$results{$backend}{$key} = {
			url			=> $mojo->req->url->to_string,
			code		=> $mojo->res->code,
			location	=> $location,
		};

		unless ($quiet) {
			say $mojo->res->code . ' ' . $mojo->req->url->to_string . ' -> ' . $location . ' ' . $backend;
			# print $mojo->res->code . ' ' . $mojo->req->url->to_string . ' -> ' . $location . ' ' . $backend . "\r";
		}

		return;
	}

	my ($content, $hash, $title);
	if ($mojo->res->headers->content_type =~ /^text\/html.*/) {
		$content = normalize_content($mojo);
		$hash = md5_hex($content);
		$title = $mojo->res->dom->at('title')->text;
	} elsif ($mojo->res->headers->content_type =~ /text\/.+/) {
		$content = $mojo->res->content->get_body_chunk;
		$hash = md5_hex($content);
		$title = $mojo->req->url->to_string;
	} else {
		$content = 'Binary: ' . $mojo->res->content->body_size . ' bytes';
		$hash = md5_hex($mojo->res->content->get_body_chunk);
		$title = $mojo->req->url->to_string;
	}

	$results{$backend}{$key} = {
		url		=> $mojo->req->url->to_string,
		code	=> $mojo->res->code,
		title	=> $title,
		hash	=> $hash,
		content	=> $content,
	};

	unless ($quiet) {
		say $mojo->req->url->to_string . ' ' . $mojo->res->code . ' ' . $backend . ' ' . md5_hex($content);
		# print $mojo->req->url->to_string . ' ' . $mojo->res->code . ' ' . $backend . ' ' . md5_hex($content) . "\r";
	}
}

# Create a standard identifier for a request
# md5 of the request method and URL
sub get_req_hash {
	my ($method, $url) = @_;

	# Remove any anchor/fragment
	$url =~ s/#.*//;

	return md5_hex($method . $url);
}

Mojo::IOLoop->recurring(
	0 => sub {
		# say $active, ' ', scalar @queue;

		# If we've reached our maximum number of connections, pause
		if ($active >= $max_conn) {
			return;
		}

		# Empty queue, but still active requests
		if ($active and not scalar @queue) {
			return;
		}

		# Check if we are finished and print summary if so
		if ($active == 0 and scalar @queue == 0) {
			say '';
			say '--------------------------------------------------------';
			say '---------------------- Summary -------------------------';
			say '--------------------------------------------------------';
			say '';

			say '------------- Errors ---------------' if scalar @errors;
			foreach my $error (sort @errors) {
				say $error;
			}

			say '------------ Mismatches ------------' if scalar @mismatches;
			foreach my $mismatch (sort @mismatches) {
				say $mismatch;
			}

			say 'Everything OK!' unless (scalar @errors or scalar @mismatches);

			Mojo::IOLoop->stop;
			return;
		}

		# say '++$active!';

		++$active;

		my $item = shift @queue;
		my $url = Mojo::URL->new($item->{url});

		# Replace the host portion of the URL with the backend
		my $host = $url->host;
		$url->host($item->{backend});

		# say $url->to_string;

		# Set Host header to the host we want (since the url is to the backend)
		# Slight hack to keep track of the tree depth; set Referer to the depth of the request
		# 	allowing us to check it in the callback.
		$ua->get($url => {Host => $host, referer => $item->{level}} => \&{$item->{callback}});
	}
);

# Start event loop
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
