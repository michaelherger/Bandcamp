package Plugins::Bandcamp::API::Sync;

use strict;

use File::Spec::Functions qw(catdir);
use HTTP::Cookies;

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Bandcamp::API::Common;

use constant API_URL_ALBUMS => '/api/fancollection/1/wishlist_items';
use constant API_URL_ALBUM  => '/api/album/2/info';
use constant API_URL_CHECKSUM => '/api/fan/2/collection_summary';

my $prefs = preferences('plugin.bandcamp');
my $log = logger('plugin.bandcamp');

my ($cache, $cookieJar, $dk);

sub init {
	my $class = shift;

	# need to initialize Cookies ourselves, as LMS only reads them in async code
	$cookieJar = HTTP::Cookies->new( file => catdir($prefs->get('cachedir'), 'cookies.dat') );
	($cache, $dk) = Plugins::Bandcamp::API::Common->init(@_);

	return $cache;
}

sub myAlbums {
	my ($class, $fan_id) = @_;

	my $now = time();
	$fan_id ||= $prefs->get('fan_id');

	my $albumData = _call({
		data => {
			fan_id  => $fan_id,
			older_than_token => time() . ':0:a::',
			count   => 10000
		},
		_url      => API_URL_ALBUMS,
		_method   => 'POST',
	});

	my $albums = [];

	if ($albumData && ref $albumData && $albumData->{items}) {
		foreach (@{$albumData->{items}}) {
			my $album = {
				added => $_->{added},
				id    => $_->{album_id},
				title => $_->{album_title},
				band_name => $_->{band_name},
				artist => $_->{band_name},
				band_id => $_->{band_id},
				cover => get_artwork_url_from_id($_->{item_art_id}) || $_->{item_art_url}
				# genre => $_->{genre_id},
			};

			push @$albums, $album;
		}
	}

	return $albums;
}

# get album info, tracks
# curl --location --request GET 'https://bandcamp.com/api/album/2/info?key=perladruslasaemingserligr&album_id=34939844' \
sub getAlbum {
	my ($class, $id) = @_;

	return _call({
		album_id  => $id,
		_url      => API_URL_ALBUM,
		_cacheTTL => META_CACHE_TTL
	});
}

sub getLibraryChecksum {
	my ($class) = @_;

	my $summary = _call({
		_url => API_URL_CHECKSUM,
		_nokey => 1,
		_noCache => 1
	});

	Plugins::Bandcamp::API::Common::calculateLibraryChecksum($summary);
}

sub _call {
	my ( $args ) = @_;

	$args->{_method} ||= 'GET';

	my ($url, $data) = Plugins::Bandcamp::API::Common->extendUrl($args);

	if ( $args->{_method} eq 'GET' && (my $cached = $cache->get('api_' . $url)) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
		return $cached;
	}
	elsif ( $args->{_cacheKey} && (my $cached = $cache->get('api_' . $args->{_cacheKey})) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
		return $cached;
	}

	my $http = Slim::Networking::SimpleSyncHTTP->new({
		nocache => $args->{_noCache} ? 1 : 0,
		timeout => 15,
	});

	my $response;
	if ($args->{_method} eq 'POST') {
		$response = $http->post($url, 'Cookie', 'identity=' . $prefs->get('identity_token'), 'Content-Type', $args->{_ct} || 'application/json', $data);
	}
	else {
		$response = $http->get($url, 'Cookie', 'identity=' . $prefs->get('identity_token'));
	}

	my $result = Plugins::Bandcamp::API::Common::parseResult($http, $args);

	return $result;
}

1;