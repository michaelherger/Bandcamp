package Plugins::Bandcamp::Scraper;

use strict;
use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Bandcamp', 'lib');

use Encode;
use HTML::TreeBuilder;
use JSON::XS qw(decode_json encode_json);

use Scalar::Util qw(blessed);
use HTML::Entities;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::API::Common;

use constant TAGS_BASE_URL => BASE_URL . 'tags/';
use constant TAG_BASE_URL  => BASE_URL . 'tag/';
use constant SEARCH_URL    => BASE_URL . 'search?q=';
use constant DAILY_URL     => 'https://daily.bandcamp.com';

# not officially documented, but worth moving to the API module?
use constant API_URL_SALES => BASE_URL . 'api/salesfeed/1/get?start_date=';
use constant DISCOVERY_URL => BASE_URL . 'api/discover/3/get_web?p=0&';
use constant GENRES_URL    => BASE_URL . 'api/discover/1/discover_web';

use constant MAX_ITEMS => 100;

my $log = logger('plugin.bandcamp');

my $cache;

sub init {
	$cache = shift;
}

sub search_tags {
	my ($client, $cb, $args) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	$search =~ s/ /-/g;

	main::DEBUGLOG && $log->debug("Searching for tag: $search");

	get_tag_items($client,
		$cb,
		$params,
		{
			tag_url => TAG_BASE_URL . $search
		}
	);
}

sub get_album_info {
	my ($client, $cb, $params, $args) = @_;

	my $album_url = $args->{album_url} || $args->{url};

	main::INFOLOG && $log->info("Getting tracks for album: $album_url");

	_get($client,
		sub {
			my $items = shift;

			my $album = shift @$items;

			if ( ref $album && !$album->{tracks} && $album->{name} && $album->{name} =~ /error.*404/i ) {
				$album = {
					error => Slim::Utils::Strings::cstring($client, 'PLUGIN_BANDCAMP_ALBUM_NOT_FOUND')
				};
			}

			# we had to squeeze the full album object into an array ref, because that's what the scraping code expects...
			$cb->($album) if $cb;
		},
		sub {
			my $tree   = shift;
			my $result = [];

			my $section = $tree->look_down("_tag", "head");

			if ($section) {
				my @scripts = $section->look_down("_tag", "script");
				foreach (@scripts) {
					my $html = $_->as_HTML;

					if ($html =~ s/.*data-tralbum="([^"]+)".*/$1/) {
						$html =~ s/&quot;/"/sg;
						my $info = eval { decode_json( Encode::encode('utf8', $html) ) };

						my $album = {
							url => $album_url
						};

						my $trackData = $info->{trackinfo};

						# if we found track data, we'll continue
						if ( $trackData && ref $trackData ) {
							if ( my $albumInfo = $info->{current} ) {
								$album->{title} = decode_entities($albumInfo->{title});
								$album->{artist} = decode_entities($albumInfo->{artist} || $info->{artist});
								$album->{art_lg_url} = get_artwork_url_from_id($albumInfo->{art_id});

								$album->{about} = decode_entities($albumInfo->{about}) if $albumInfo->{about};
								$album->{band_id} = $albumInfo->{band_id} if $albumInfo->{band_id};
								$album->{credits} = decode_entities($albumInfo->{credits}) if $albumInfo->{credits};
								$album->{release_date} = $albumInfo->{release_date} if $albumInfo->{release_date};
							}


							if ( $info->{packages} && ref $info->{packages} eq 'ARRAY' ) {
								foreach (@{$info->{packages}}) {
									if ($_->{album_id}) {
										$album->{album_id} = $_->{album_id};
										last;
									}
								}
							}
						}

						$album->{tracks} = [ map {
							$_->{number} = $_->{track_num};
							$_->{streaming_url} = $_->{file};
							cache_track_info($_, $album);
						} @$trackData ];

						$result = [$album];
					}
				}
			}

			$cache->set( $album_url, $result, USER_CACHE_TTL ) if scalar @$result;

			return $result;
		},
		$params,
		$album_url,
		$album_url
	);
}

sub get_playlist_page {
	my ( $client, $cb, $params, $args ) = @_;

	my $url = $args->{url} || '';

	main::DEBUGLOG && $log->debug("Getting playlist page: $url");

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my $playlistPage = $tree->look_down("_tag", "div", "id", "PlaylistPage");

			if ($playlistPage) {
				my $data = $playlistPage->attr('data-blob');

				$data = eval { decode_json( Encode::encode( 'utf8', $data) ) };

				if ($@ || !$data) {
					$log->error($@);
				}
				elsif ( ref $data && $data->{appData} && (my $trackData = $data->{appData}->{tracks}) ) {
					my $playlist = {
						url => $url,
						title => $data->{appData}->{title} || '',
						description => $data->{appData}->{description} || '',
						playlist_id => $data->{appData}->{playlistId} || '',
						art_lg_url => $data->{appData}->{imageId} || '',
					};

					$result = [ map {
						my $track = $trackData->{$_};
						$track->{number} = $_;

						if ($track->{album} && ref $track->{album}) {
							my $album = $track->{album};
							$track->{streaming_url} = $track->{streamUrl};
							$track->{album_url} = $album->{url};
							$track->{album} = $album->{title};
						}
						cache_track_info($track, $playlist);
					} sort keys %$trackData ];
				}
			}

			$cache->set( $url, $result, USER_CACHE_TTL ) if scalar @$result;

			return $result;
		},
		$params,
		$url,
		$url
	);
}

sub get_fan_page {
	my ( $client, $cb, $params, $args ) = @_;

	my $fan = $args->{fan} || '';

	main::DEBUGLOG && $log->debug("Getting fan page for: $fan");

	my $cache_key = "fanpage/$fan";

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = {};

			my $collection = $tree->look_down("_tag", "div", "id", "pagedata");

			if ($collection) {
				my $data = $collection->attr('data-blob');

				$data = eval { decode_json( Encode::encode( 'utf8', $data) ) };

				if ($@ || !$data) {
					$log->error($@);
				}
				else {
					# extract the fan_id if possible
					if ( (my $fan_data = $data->{fan_data}) && (my $fan = $args->{fan}) ) {
						if ( my $fan_id = $fan_data->{fan_id} ) {
							main::INFOLOG && $log->info("Caching Fan ID for '$fan': $fan_id");
							$cache->set('user_id_' . $fan, $fan_id, META_CACHE_TTL);
						}
					}

					if ( my $items = $data->{item_cache} ) {
						foreach my $type ( qw(collection wishlist) ) {
							if ( $items->{$type} && ref $items->{$type} && keys %{$items->{$type}} ) {
								$result->{$type} = [ sort {
									uc($a->{title}) cmp uc($b->{title})
								} @{ Plugins::Bandcamp::API::parse_album_list([ values %{$items->{$type}} ]) } ];
							}
						}

						foreach my $type ( qw(following_bands following_fans followers) ) {
							if ( $items->{$type} && ref $items->{$type} && keys %{$items->{$type}} ) {
								$result->{$type} = [ sort {
									uc($a->{name}) cmp uc($b->{name})
								}  @{ Plugins::Bandcamp::API::parse_artist_list([ values %{$items->{$type}} ]) } ];
							}
						}
					}
				}
			}

			$cache->set( $cache_key, $result, USER_CACHE_TTL ) if keys %$result; # && _shall_cache($params);

			return [$result];
		},
		$params,
		$cache_key,
		BASE_URL . $fan
	);
}

sub get_tag_list {
	my ( $client, $cb, $params ) = @_;

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];
			my %seen;

			my @categories = $tree->look_down("_tag", "div", "class", qr/tagcloud/);

			foreach my $tag_cloud (@categories) {
				my $type = $tag_cloud->attr('id') || next;

				foreach ($tag_cloud->content_list) {
					next unless blessed($_) && $_->attr('class') =~ /\btag\b/ && ref $_->content eq 'ARRAY';

					my $name = $_->content->[0];
					next if $seen{$name}++;

					push @$result, {
						name  => $name,
						url   => $_->attr('href'),
						cloud => $type,
					}
				}
			}

			$cache->set( 'taglist', $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'taglist',
		TAGS_BASE_URL,
	);
}

sub search_fans {
	my ( $client, $cb, $args ) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my @fans = $tree->look_down("_tag", "li", "class", qr/searchresult fan/);

			foreach my $fan (@fans) {
				if ($fan) {
					my $fan_item = {};

					my $fan_details = $fan->look_down("_tag", "div", "class", "heading");
					foreach ($fan_details->content_list) {
						next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

						$fan_item->{name} = $_->content->[0];
						$fan_item->{name} =~ s/^\s*|\s*$//g;

						$fan_item->{offsite_url} = $_->attr('href');
						$fan_item->{offsite_url} =~ s/\?.*//;

						if ( $fan_item->{offsite_url} =~ m|([^/]+$)| ) {
							$fan_item->{fan} = $1;
						}
					}

					if ( my $fan_img = $fan->look_down("_tag", "img") ) {
						$fan_item->{art_lg_url} = $fan_img->attr('src');
					}

					push @$result, $fan_item;
				}
			}

			$cache->set( 'fan_list' . $search, $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'fan_list' . $search,
		SEARCH_URL . $search,
	);
}

sub search {
	my ( $client, $cb, $args ) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my @items = $tree->look_down("_tag", "li", "class", qr/searchresult data-search/);

			foreach my $item (@items) {
				my $searchInfo = eval { decode_json($item->attr('data-search')) };
				$log->error("Failed to parse search result item: $@") if $@;

				my $type = $searchInfo->{type} if $searchInfo;

				if ($type eq 't') {
					my $track_item = {};

					my $track_details = $item->look_down("_tag", "div", "class", "heading");
					foreach ($track_details->content_list) {
						next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

						$track_item->{name} = $_->content->[0];
						$track_item->{name} =~ s/^\s*|\s*$//g;

						$track_item->{offsite_url} = $_->attr('href');

						if ( $track_item->{offsite_url} =~ m|search_item_id=(\d+)| ) {
							$track_item->{track_id} = $1;
						}

						$track_item->{offsite_url} =~ s/\?.*//;

						next unless $track_item->{track_id};
					}

					if ( my $track_artist = $item->look_down("_tag", "div", "class", "subhead") ) {
						$track_item->{artist} = $track_artist->content->[0];
						$track_item->{artist} =~ s/.* by (.*?)/$1/;
						$track_item->{artist} =~ s/^\s*|\s*$//g;
					}

					if ( my $track_img = $item->look_down("_tag", "img") ) {
						$track_item->{art_lg_url} = $track_img->attr('src');
						$track_item->{art_lg_url} =~ s/_7\./_5./;
					}

					push @$result, $track_item;
				}
				elsif ($type eq 'a') {
					my $album_item = {};

					my $album_details = $item->look_down("_tag", "div", "class", "heading");
					foreach ($album_details->content_list) {
						next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

						$album_item->{album} = $_->content->[0];
						$album_item->{album} =~ s/^\s*|\s*$//g;

						$album_item->{album_url} = $_->attr('href');

						if ( $album_item->{album_url} =~ m|search_item_id=(\d+)| ) {
							$album_item->{album_id} = $1;
						}

						$album_item->{album_url} =~ s/\?.*//;
						$album_item->{url} = $album_item->{album_url};

						next unless $album_item->{album_id};
					}

					if ( my $album_artist = $item->look_down("_tag", "div", "class", "subhead") ) {
						$album_item->{artist} = $album_artist->content->[0];
						$album_item->{artist} =~ s/^ by //;
						$album_item->{artist} =~ s/^\s*|\s*$//g;
					}

					if ( my $album_img = $item->look_down("_tag", "img") ) {
						$album_item->{art_lg_url} = $album_img->attr('src');
					}

					push @$result, $album_item;
				}
				elsif ($type eq 'b') {
					push @$result, _parse_band_element($item);
				}
			}

			$cache->set( 'search_list' . $search, $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'search_list' . $search,
		SEARCH_URL . $search,
	);
}

sub search_artists {
	my ( $client, $cb, $args ) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			foreach ( $tree->look_down("_tag", "li", "class", qr/searchresult band/) ) {
				if ($_) {
					push @$result, _parse_band_element($_);
				}
			}

			$cache->set( 'artist_list' . $search, $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'artist_list' . $search,
		SEARCH_URL . $search,
	);
}

sub _parse_band_element {
	my $band = shift;
	my $band_item = {};

	my $band_details = $band->look_down("_tag", "div", "class", "heading");
	foreach ($band_details->content_list) {
		next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

		$band_item->{name} = $_->content->[0];
		$band_item->{name} =~ s/^\s*|\s*$//g;

		$band_item->{offsite_url} = $_->attr('href');

		if ( $band_item->{offsite_url} =~ m|search_item_id=(\d+)| ) {
			$band_item->{band_id} = $1;
		}

		$band_item->{offsite_url} =~ s/\?.*//;

		next unless $band_item->{band_id};
	}

	if ( my $band_img = $band->look_down("_tag", "img") ) {
		$band_item->{art_lg_url} = $band_img->attr('src');
	}

	return $band_item;
}

sub get_tag_items {
	my ($client, $cb, $params, $args) = @_;
	$params ||= {};

	my ($tag) = reverse split(/\//, $args->{tag_url} || '');

	_get($client,
		sub {
			my $results = shift || {};
			my $items = [ map {
				{
					artist        => decode_entities($_->{album_artist} || $_->{band_name}),
					title         => decode_entities($_->{title}),
					band_id       => $_->{band_id},
					large_art_url => get_artwork_url_from_id($_->{item_image_id}),
					url           => $_->{item_url},
				}
			} @{$results->{results} || []} ];

			$cb->({
				discography => $items
			});
		},
		sub {},
		{
			%$params,
			postBody => {
				'tag_norm_names' => [$tag],
				'slice' => 'top',
				'size' => MAX_ITEMS,
				'include_result_types' => ['a', 's']
			},
		},
		'tag_albums_' . $args->{tag_url},
		GENRES_URL
	);
}

sub get_sales_feed {
	my ($client, $cb, $params) = @_;

	main::DEBUGLOG && $log->debug("Getting sales feed");

	if ( $params->{use_cache} && (my $cached = $cache->get('sales_feed_' . $client->id)) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
		$cb->($cached) if $cb;
		return;
	}

	_get($client,
		sub {
			my $items = shift;

			my @albums;
			my %seen;

			foreach my $event (reverse @{$items->{events}}) {
				next unless $event->{event_type} && $event->{event_type} eq 'sale';

				foreach ( reverse @{$event->{items}} ) {
					# we only want packages with artwork, albums and tracks
					next unless $_->{item_type} && $_->{item_type} eq 'a'; # =~ /^[atp]$/;

					my $meta = {
						artist => decode_entities($_->{artist_name}),
						title  => decode_entities($_->{item_description}),
						large_art_url => get_complete_url($_->{art_url}) || get_artwork_url_from_id($_->{art_id}),
						url    => get_complete_url($_->{url}) || get_url_from_hints($_->{url_hints}),
					};

					# if ($_->{item_type} eq 't') {
					# 	Plugins::Bandcamp::API::get_item_info_by_url($client,
					# 		sub {
					# 			my ($items) = shift;

					# 			if ($items && ref $items && ref $items eq 'HASH' && $items->{track_id}) {
					# 				Plugins::Bandcamp::API::get_track_info($items);
					# 			}
					# 		},
					# 		$params,
					# 		$meta,
					# 	);
					# }

					next if $seen{$meta->{url}};

					$seen{$meta->{url}} = 1;

					push @albums, $meta;
				}
			}

			$cache->set('sales_feed_' . $client->id, \@albums, CACHE_TTL * 5);

			$cb->(\@albums) if $cb;
		},
		undef,
		$params,
		undef,
		API_URL_SALES . (time() - 600),
	);
}

sub get_discovery {
	my ( $client, $cb, $params, $args ) = @_;

	my $nocache  = delete $args->{nocache};
	my $url      = delete $args->{url};
	my $orig_url = $url;

	if ( $url && !$args->{s} ) {
		($args->{s}) = $url =~ /s=([a-z]+)/;
	}

	$url ||= DISCOVERY_URL . join('&', map { "$_=" . $args->{$_} } keys %$args);

	if ( !$nocache && (my $cached = $cache->get($url . ($client ? $client->id : ''))) ) {
		$cb->({
			discography => $cached
		}) if $cb;
		return;
	}

	_get(undef,
		sub {
			my $data = shift;

			my $items = [];
			my %genres;

			foreach ( @{$data->{items}} ) {
				my $large_art = $_->{art_lg_url} || $_->{large_art};

				push @$items, {
					title         => decode_entities($_->{primary_text}),
					artist        => decode_entities($_->{secondary_text}),
					band_id       => $_->{band_id},
					large_art_url => $large_art || $_->{art} || $_->{full_art} || get_artwork_url_from_id($_->{art_id}),
					url           => $_->{url} || get_url_from_hints($_->{url_hints}),
				};

				# small artwork version
				if ( $large_art && $_->{art} && $large_art ne $_->{art} ) {
					$cache->set('small_' . $large_art, $_->{art}, META_CACHE_TTL);
				}

				# full size artwork
				if ( $_->{full_art} && $large_art && $_->{full_art} ne $large_art ) {
					$cache->set('full_' . $large_art, $_->{full_art}, META_CACHE_TTL);
				}
			}

			if ( $data->{args} && !$orig_url && ref $data->{args}->{g} ) {
				while ( my ($k, $v) = each %{$data->{args}->{g}} ) {
					$genres{$k} = $v;
				}
			}

			foreach ( sort keys %genres ) {
				next if /^all$/;

				push @$items, {
					title => ucfirst($_),
					url   => DISCOVERY_URL . $genres{$_},
					type  => 'link',
				}
			}

			if ( !$nocache && scalar @$items ) {
				$cache->set($url . ($client ? $client->id : 'xxx'), $items, CACHE_TTL);
			}

			$cb->({
				discography => $items
			}) if $cb;
		},
		undef,
		undef,
		undef,
		$url
	);
}

sub get_daily_list {
	my ($cb) = @_;

	_get(undef,
		sub {
			$cb->({
				daily_list => shift
			}) if $cb;
		},
		sub {
			my $tree   = shift;
			my $result = [];

			my $dailies_list = $tree->look_down("_tag", "div", "class", "latest-section");

			if (scalar $dailies_list) {
				my @dailies = $dailies_list->look_down("_tag", "div", "class", "list-article  ");

				foreach my $daily (@dailies) {
					my $titleItem = $daily->look_down("_tag", "a", "class", "title");
					my $imageItem = $daily->look_down("_tag", "img");

					push @$result, {
						name => $titleItem->content->[0],
						url => DAILY_URL . $titleItem->attr('href'),
						cover => $imageItem->attr('src'),
					};
				}

				$cache->set(DAILY_URL, $result, 3600);
			}

			return $result;
		},
		undef,
		DAILY_URL,
		DAILY_URL
	);
}

sub get_daily_show {
	my ( $cb, $args ) = @_;

	_get(undef,
		sub {
			my $items = shift;

			$cb->({
				tracks => [ grep { !$_->{tracks} } @$items ],
				albums => [ grep { $_->{tracks} } @$items ],
			});
		},
		sub {
			my $tree   = shift;
			my $tracks = [];
			my $albums = [];
			my $results = [];

			my $dailies = $tree->look_down("_tag", "div", "id", "p-daily-article");

			if (scalar $dailies) {
				my $data = $dailies->attr('data-player-infos');

				$data = eval { decode_json( Encode::encode( 'utf8', $data) ) };

				if ($@ || !$data || !ref $data) {
					$log->error($@);
				}

				foreach my $item (@$data) {
					my $type = $item->{tralbum_type} || '';

					my $album = {
						url => $item->{tralbum_url},
						title => $item->{title},
						artist => $item->{band_name},
						band_id => $item->{band_id},
						art_lg_url => get_artwork_url_from_id($item->{art_id}),
					};

					foreach (@{$item->{tracklist}}) {
						cache_track_info($_, $album);
					}

					$album->{tracks} = [ map {
						cache_track_info($_, $album);
					} @{$item->{tracklist}} ];

					push @$results, $album;

					my $rawTrack = $item->{tracklist}->[$item->{featured_track_number}-1] if $item->{featured_track_number};

					if ($rawTrack) {
						my $track = {
							title    => $rawTrack->{track_title},
							artist   => $album->{artist},
							band_id  => $album->{band_id},
							album    => $album->{title},
							album_id => $rawTrack->{album_id},
							large_art_url => get_artwork_url_from_id($rawTrack->{art_id}),
							track_id => $rawTrack->{track_id},
							streaming_url => $rawTrack->{streaming_url},
							duration => $rawTrack->{audio_track_duration},
						};

						push @$results, $track;
					}
				}

				$cache->set($args->{url}, $results, CACHE_TTL);
			}

			return $results;
		},
		undef,
		$args->{url},
		$args->{url}
	);
}

sub get_complete_url {
	my $url = $_[0];

	return $url if $url =~ /^http/;
	return 'http:' . $url;
}

#  url_hints => {
#        custom_domain => "vestbotrio.com",
#        "custom_domain_verified" => 1,
#        item_type => "a",
#        slug => "flowmotion",
#        subdomain => "vestbotrio",
#      },
#  url_hints => {
#        custom_domain => undef,
#        "custom_domain_verified" => undef,
#        item_type => "a",
#        slug => "git-witt-u",
#        subdomain => "fsgreen",
#      },
my $item_types = {
	a => 'album',
	t => 'track',    # just a guess...
	p => 'merch',
};

sub get_url_from_hints {
	my $hints = shift;

	my $url = $hints->{custom_domain};
	$url  ||= $hints->{subdomain};

	return unless $url;

	$url .= '.bandcamp.com' unless $hints->{custom_domain};

	return sprintf('http://%s/%s/%s', $url, $item_types->{$hints->{item_type}}, $hints->{slug});
}

sub _get {
	my ($client, $cb, $parseCB, $params, $tag, $url) = @_;

	if ( $tag && (my $cached = $cache->get($tag)) ) {
		main::INFOLOG && $log->is_info && $log->info("found cached value for '$tag'");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->( $cached );
		return;
	}

	$url = BASE_URL . $url if $url =~ m|^/|;
	# remove double slashes in the URL (happens sometimes in the tag URLs)
	$url =~ s/(\.com)\/\//$1\//g;

	main::INFOLOG && $log->is_info && $log->info("GETting $url");

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');

			my $result;
			my $error;

			#warn Data::Dump::dump($response->content);

			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->parse_content( Encode::decode( 'utf8', $response->content) );

				$result = $parseCB->($tree) if $parseCB;

				if (!scalar @$result) {
					$result = [];
				}
			}
			elsif ( $response->headers->content_type =~ /json/ ) {
				$result = decode_json(
					$response->content,
				);
			}

			if (!$result) {
				$result = [ 'Error: Invalid data' ];
				$log->error($result->[0]);
			}

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			$cb->($result);
		},
		sub {
			$log->warn("error: $_[1]");
			$cb->([ {
				name => 'Unknown error: ' . $_[1],
				type => 'text'
			} ]);
		},
		{
			params  => $params,
			client  => $client,
			timeout => 30,
		},
	);

	if ($params->{postBody}) {
		$http->post($url, 'Content-Type' => 'application/json', encode_json($params->{postBody}));
	}
	else {
		$http->get($url);
	}
}

# sub _shall_cache {
# 	my $params = shift;
# 	return ( ($params->{isControl} && $params->{index}) || ($params->{isWeb} && defined $params->{index}) ) ? 1 : 0;
# }

1;