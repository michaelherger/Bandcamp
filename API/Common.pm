package Plugins::Bandcamp::API::Common;

use strict;

use Exporter::Lite;

our @EXPORT = qw(
	cache_track_info get_artwork_url_from_id track_key track_url
	BASE_URL CACHE_TTL META_CACHE_TTL USER_CACHE_TTL
);

use Digest::MD5 qw(md5_hex);
use Encode;
use JSON::XS qw(decode_json encode_json);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL    => 'https://bandcamp.com/';
use constant ARTWORK_URL => 'http://f0.bcbits.com/';

use constant CACHE_TTL      => 3600 * 12;
use constant META_CACHE_TTL => 86400 * 30;
use constant USER_CACHE_TTL => 60 * 5;

my $prefs = preferences('plugin.bandcamp');
my $log = logger('plugin.bandcamp');

my ($cache, $dk);

sub init {
	my ($class, $pluginData) = @_;

	$pluginData ||= {};

	$cache = Slim::Utils::Cache->new('bandcamp', $pluginData->{cacheVersion});
	$dk = $pluginData->{dk};
	$dk =~ s/-//g;

	return wantarray ? ($cache, $dk) : $cache;
}

sub calculateLibraryChecksum {
	my $summary = shift || return;

	my $checksum;
	if (ref $summary && $summary->{collection_summary}) {
		my $albums = $summary->{collection_summary}->{tralbum_lookup} || {};
		$checksum = md5_hex(join('::', sort grep {
			!$albums->{$_}->{purchased}
		} keys %$albums));
	}

	main::INFOLOG && $log->is_info && $log->info("Library checksum: $checksum");
	return $checksum;
}

sub extendUrl {
	my ($class, $args) = @_;

	my $url = delete $args->{_url};
	$url = BASE_URL . $url unless $url =~ /^http/;

	my $method = $args->{_method} || 'GET';
	my $data;

	if ($method eq 'POST') {
		$data = ref $args->{data} ? encode_json($args->{data}) : $args->{data};

		main::INFOLOG && $log->info($url . ": \n" . Data::Dump::dump($data));
	}
	else {
		$url .= ($args->{_nokey} ? '?' : '?key=' . $dk);

		for my $k ( keys %{$args} ) {
			next if $k =~ /^_/;
			$url .= '&' . $k . '=' . ($args->{_no_escape} ? $args->{$k} : uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) ));
		}

		$url =~ s/\?&/?/;
		$url =~ s/\?$//;

		main::INFOLOG && $log->info( $url =~ s/\Q$dk\E/.../r );
	}


	return wantarray ? ($url, $data) : $url;
}

sub parseResult {
	my ($http, $args) = @_;

	my $result;

	if ( $http->headers->content_type =~ /json/ ) {
		$result = decode_json(
			$http->content,
		);

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

		if ( !$result || $result->{error} ) {
			$result = {
				error => 'Error: ' . ($result->{error_message} || 'Unknown error')
			};

			$log->error($result->{error} . ' (' . $http->url . ')');
		}
		elsif ( !$http->params('nocache') && $http->type ne 'POST' ) {
			$cache->set('api_' . $http->url, $result, $http->params('_cacheTTL') || CACHE_TTL);
		}
		elsif ( $args && $args->{_cacheKey} ) {
			$cache->set('api_' . $args->{_cacheKey}, $result, $args->{'_cacheTTL'} || CACHE_TTL);
		}
	}
	else {
		$log->error("Invalid data");
		$result = {
			error => 'Error: Invalid data',
		};
	}

	return $result;
}

sub cache_track_info {
	my ($track, $album) = @_;

	if (my $url = $track->{streaming_url} || $track->{audio_url}) {
		# sometimes we get a hash for the streaming_url? Pick the 128kbps or some random other stream
		if (ref $url eq 'HASH') {
			$url = $url->{'mp3-128'} || $url->{(keys %$url)[0]};
			$track->{streaming_url} = $url;
		}

		$track->{streaming_url} = HTML::Entities::decode_entities($track->{streaming_url});

		$track->{title} = HTML::Entities::decode_entities($track->{title});
		$track->{number} ||= $track->{track_number} || $track->{track_number};

		# use album information to complete track information if available
		if ($album) {
			$track->{artist} ||= $album->{artist} || $track->{artistName};
			$track->{album}  ||= $album->{title};
			$track->{image}  ||= $track->{art_lg_url} || $track->{large_art_url} || $album->{art_lg_url} || $album->{large_art_url} || $album->{small_art_url};
			$track->{album_url} ||= $album->{url};
		}

		# complete with cached values if needed
		my $key = $track->{track_id} || track_key($track->{streaming_url});
		if ( my $cached = $cache->get('meta_' . $key) ) {
			foreach (keys %$cached) {
				$track->{$_} ||= $cached->{$_};
			}
		}

		if ( ($track->{art_lg_url} || $album->{art_lg_url} || $track->{large_art_url} || $album->{large_art_url}) && (my $small = $track->{small_art_url} || $album->{small_art_url}) ) {
			$cache->set('small_' . $track->{image}, $small, META_CACHE_TTL);
		}

		# xxx - track api is broken, returning relative URLs; get domain name from album url
		if ($track->{url} && $track->{url} =~ m|^/| && $track->{album_url}) {
			my ($prefix) = $track->{album_url} =~ m|(http://.*?)/|;

			$track->{url} = $prefix . $track->{url};
		}

		$cache->set('meta_' . $key, $track, META_CACHE_TTL);
	}

	return $track;
}

sub track_key {
	my $url = shift;

	if ($url =~ /id=(\d+)/i) {
		return $1;
	}
	elsif ($url =~ /bcbits.*?\/stream\/.*?\/(\d+)\?/i) {
		return $1;
	}
	elsif ($url =~ m|bandcamp://(.*?)\.mp3|) {
		return $1;
	}

	return '';
}

# durable bandcamp:// URL for a track id; re-resolved at play time, so
# saved favourites and queues survive the stream token expiring
sub track_url {
	my $id = shift;
	return $id ? "bandcamp://$id.mp3" : undef;
}

# 0 => original (size & format, don't use extension)
# 1 => fullsize (dito, use .original?, even heavier?!?)
# 2 => 350x350 jpg
# 3 => 100x100 jpg
# 4 => 300x300 jpg
# 5 => 700x700 jpg
# 7 => 150x150 jpg
# 8 => 124x124 jpg
# 9 => 210x210 jpg
# 10 => 1200x1200 jpg
# non-artwork related, but working?
# 20 => 1024x1024 jpg
# 22 => 25x25 jpg
# 41 => 210x210 jpg
# 42 => 50x50 jpg
sub get_artwork_url_from_id {
	my ($image_id, $format, $type) = @_;

	$type = 'a' unless defined $type;
	$format ||= 5; # to be tweaked!

	$image_id = substr("000000000" . $image_id, -10);

	return sprintf('%simg/%s%s_%s.jpg', ARTWORK_URL, $type, $image_id, $format);
}

1;