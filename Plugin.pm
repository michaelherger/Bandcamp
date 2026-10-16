package Plugins::Bandcamp::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use Tie::Cache::LRU;

use Slim::Formats::RemoteMetadata;
use Slim::Menu::GlobalSearch;
use Slim::Menu::TrackInfo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::API::Common;
use Plugins::Bandcamp::ProtocolHandler;
use Plugins::Bandcamp::Scraper;
use Plugins::Bandcamp::Search;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.bandcamp',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_BANDCAMP',
} );

my $prefs = preferences('plugin.bandcamp');

use constant PLUGIN_TAG       => 'bandcamp';
use constant STREAM_URL_REGEX => qr{(?:bcbits|bandcamp)\.com/(?:download/track|stream/[a-z0-9]+/|stream_redirect\b)}i;
use constant IMAGES_URL_REGEX => qr{f0\.bcbits\.com/(?:img|z)/};
use constant MAX_RECENT_ITEMS => 50;
use constant RECENT_CACHE_TTL => 'never';
use constant RECENT_CACHE_KEY => 'recent_plays_v2';

my $cache;

my %recent_plays;
tie %recent_plays, 'Tie::Cache::LRU', MAX_RECENT_ITEMS;

my $does_scrobble;

sub initPlugin {
	my $class = shift;

	$cache = Slim::Utils::Cache->new('bandcamp', $class->_pluginDataFor('cacheVersion'));

	if ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		$log->error(string('PLUGIN_BANDCAMP_MISSING_SSL'));
	}

	if (my $username = $prefs->get('username')) {
		$prefs->set('username', '') if $username eq '_bandcamp_';
	}

	$prefs->init({
		username => '_bandcamp_'
	});

	# when user enters an identity token, store it in the cookie jar, too
	$prefs->setChange(sub {
		my ($pref, $new, $obj, $old) = @_;

		my $cookies = Slim::Networking::Async::HTTP->cookie_jar;
		if ($new) {
			# XXX - not working?
			$new =~ s/^identity[:=]//;
			$cookies->set_cookie(0, 'identity', $new, '/', 'bandcamp.com');
		}
		else {
			$cookies->clear('bandcamp.com', '/', 'identity');
		}

		$cache->clear;
	}, 'identity_token');

	$prefs->setValidate({
		validator => sub {
			# if there's a slash, the user likely pasted the full path instead of the username only
			return if $_[1] =~ m|/|;
			return 1;
		}
	}, 'username');

	($prefs->get('username') || '') =~ m|/| && $log->error("Invalid username: " . $prefs->get('username'));

	Plugins::Bandcamp::API::init(Slim::Utils::PluginManager->dataForPlugin($class));
	Plugins::Bandcamp::Scraper::init( $cache );
	Plugins::Bandcamp::Search::init( $cache );

#                                                                            |requires Client
#                                                                            |  |is a Query
#                                                                            |  |  |has Tags
#                                                                            |  |  |  |Function to call
#                                                                            C  Q  T  F
	Slim::Control::Request::addDispatch(['bandcamp', 'recentlyplayed'], [1, 0, 1, \&Plugins::Bandcamp::Plugin::recently_played_cli]);
	Slim::Control::Request::addDispatch(['bandcamp', 'recentsearches'], [1, 0, 1, \&Plugins::Bandcamp::Search::recent_searches_cli]);

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		bandcamp => 'Plugins::Bandcamp::ProtocolHandler'
	);

	Slim::Formats::RemoteMetadata->registerProvider(
		match => STREAM_URL_REGEX,
		func  => \&metadata_provider,
	);

	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( bandcamp => (
		after => 'moreinfo',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( bandcamp => (
		before => 'middle',
		func   => sub {
			my ( $client, $tags ) = @_;

			my $searchParam = $tags->{search};
			my $passthrough = [{ q => $searchParam }];

			return [{
				name  => cstring($client, 'PLUGIN_BANDCAMP'),
				items => [{
					name        => cstring($client, 'SEARCHFOR_ARTISTS'),
					url         => \&Plugins::Bandcamp::Search::search_artists,
					passthrough => $passthrough,
					searchParam => $searchParam,
				},{
					name        => cstring($client, 'PLUGIN_BANDCAMP_SEARCHFOR_TAGS'),
					url         => \&Plugins::Bandcamp::Search::search_tags,
					passthrough => $passthrough,
					searchParam => $searchParam,
				}]
			}]
		},
	) );

	# initialize recent plays: need to add them to the LRU cache ordered by timestamp
	my $recent_plays = $cache->get(RECENT_CACHE_KEY) || undef;
	my $old_recent_plays;
	if ((!$recent_plays || !ref $recent_plays) && ($old_recent_plays = $cache->get('recent_plays')) && ref $old_recent_plays) {
		main::INFOLOG && $log->is_info && $log->info("Re-keying recently played data by URL");
		foreach my $item (values %$old_recent_plays) {
			$recent_plays->{$item->{url}} = $item;
		}
		$cache->set(RECENT_CACHE_KEY, $recent_plays, RECENT_CACHE_TTL);
		$cache->remove('recent_plays')
	}

	if (!$recent_plays || !ref $recent_plays) {
		main::INFOLOG && $log->is_info && $log->info("Corrupted recent plays data - re-initializing");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($recent_plays));
		$recent_plays = {};
	}

	map {
		$recent_plays{$_} = $recent_plays->{$_};
	} sort {
		$recent_plays->{$a}->{ts} <=> $recent_plays->{$b}->{ts}
	} keys %$recent_plays;

	# try to load custom artwork handler - requires recent LMS 7.8 with new image proxy
	eval {
		require Slim::Web::ImageProxy;

		# XXX - some might not have updated their 7.8 yet...
		if ( UNIVERSAL::can('Slim::Web::ImageProxy', 'getRightSize') ) {

		Slim::Web::ImageProxy->registerHandler(
			match => IMAGES_URL_REGEX,
			func  => sub {
				my ($url, $spec) = @_;

				if (my ($art_id) = $url =~ m|f0\.bcbits\.com/img/a(\d+)_|) {
					my $size = Slim::Web::ImageProxy->getRightSize($spec, {
						25 => 22,
						50 => 42,
						100 => 3,
						124 => 8,
						150 => 7,
						210 => 9,
						300 => 4,
						350 => 2,
						700 => 5,
						1024 => 20,
						# 0 => original (size & format, don't use extension)
					}) || '2';
					$url = get_artwork_url_from_id($art_id, $size);
				}
				else {
					my $size = Slim::Web::ImageProxy->getRightSize($spec, { 100 => 'small_', 350 => '' }) || 'full_';
					$url = $cache->get("$size$url") || $url;
				}

				return $url;
			},
		);
		main::DEBUGLOG && $log->debug("Successfully registered image proxy for Bandcamp artwork");

		}
	} if preferences('server')->get('useLocalImageproxy');

	if (main::WEBUI) {
		require Plugins::Bandcamp::Settings;
		Plugins::Bandcamp::Settings->new();
	}

	if ($prefs->get('enableImporter')) {
		eval {
			require Plugins::Bandcamp::Importer;
			Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('bandcamp', '/plugins/Bandcamp/html/images/bc.png');

			# tell LMS that we need to run the external scanner
			Slim::Music::Import->addImporter('Plugins::Bandcamp::Importer', { use => 1 });
		}
	}
}

sub postinitPlugin {
	my $class = shift;

	if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
		eval {
			require Plugins::Bandcamp::HomeExtras;
		};
		$log->error("Could not load Bandcamp Home Extras: $@") if $@;
	}
}

sub getDisplayName { 'PLUGIN_BANDCAMP' }

# don't add this plugin to the Extras menu
sub playerMenu {}


sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $params = $args->{params};

	if ($args->{params} && (my $menu = $args->{params}->{menu})) {
		if ($menu eq 'home_heroes_daily') {
			return get_daily_shows( $client, $cb );
		}
		elsif ($menu eq 'home_heroes_weekly') {
			return get_weekly_shows( $client, $cb );
		}
		elsif ($menu eq 'home_heroes_recently_played') {
			return recently_played( $client, $cb );
		}
	}

	my $items = [
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_DAILY'),
			type => 'link',
			url  => \&get_daily_shows,
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_WEEKLY'),
			type => 'link',
			url  => \&get_weekly_shows,
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_TOPSELLERS'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'top'
			}],
		},
		# {
		# 	name => cstring($client, 'PLUGIN_BANDCAMP_STAFF_PICKS'),
		# 	type => 'link',
		# 	url  => \&get_discovery,
		# 	passthrough => [{
		# 		s => 'pic'
		# 	}],
		# },
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_NEW_ARRIVALS'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'new'
			}],
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_MOST_RECOMMENDED'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'rec',
				r => 'most',
			}],
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_SELLING'),
			type => 'link',
			url  => \&get_selling_items,
		},
		{
			name  => cstring($client, 'PLUGIN_BANDCAMP_RECENTLY_PLAYED'),
			type => 'link',
			url  => \&recently_played,
		},
		{
			name => cstring($client, 'GENRES'),
			type => 'link',
			url  => \&get_tags,
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_LOCATIONS'),
			type => 'link',
			url  => \&get_locations,
		},
		{
			name  => cstring($client, 'SEARCH'),
			type => 'search',
			url  => \&Plugins::Bandcamp::Search::search
		},
		{
			name => cstring($client, 'RECENT_SEARCHES'),
			type => 'link',
			url  => \&Plugins::Bandcamp::Search::recent_searches,
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_URL'),
			type => 'search',
			url  => \&Plugins::Bandcamp::Search::search_url,
		}
	];

	my $username = $prefs->get('username');

	if ($username eq '_bandcamp_') {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_BANDCAMP_MY_MUSIC'),
			items => [{
				name => cstring($client, 'PLUGIN_BANDCAMP_FAN_MISSING'),
				type => 'textarea',
			}]
		};
	}
	elsif ($username) {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_BANDCAMP_MY_MUSIC'),
			type => 'link',
			url  => \&get_fan_page,
			passthrough => [{
				fan => $username
			}],
		};
	}

	if (!Slim::Networking::Async::HTTP->hasSSL()) {
		$items = [{
			name => cstring($client, 'PLUGIN_BANDCAMP_MISSING_SSL'),
			type => 'textarea'
		}];
	}

	$cb->({
		items => $items,
	});
}

sub get_fan_page {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_fan_page($client,
		sub {
			my $data = shift;

			if ( $args->{fan}  && $args->{fan} eq ($prefs->get('username') || '') && (my $id = $cache->get('user_id_' . $args->{fan})) ) {
				main::INFOLOG && $log->info("Storing Fan ID for ourselves in prefs for faster access: $id");
				$prefs->set('fan_id', $id);
			}

			$data = shift @$data if $data && ref $data && ref $data eq 'ARRAY';
			my $items = [];

			if (!$args->{id}) {
				foreach (
					['collection', 'PLUGIN_BANDCAMP_FANPAGE', 'collection_items'],
					['wishlist', 'PLUGIN_BANDCAMP_FAN_WISHLIST', 'wishlist_items'],
					['following_bands', 'PLUGIN_BANDCAMP_FAN_FOLLOWING_BANDS'],
					['following_fans', 'PLUGIN_BANDCAMP_FAN_FOLLOWING_FANS'],
					['followers', 'PLUGIN_BANDCAMP_FAN_FOLLOWERS'],
				) {
					if ( $data->{$_->[0]} ) {
						push @$items, {
							name => cstring($client, $_->[1]),
							type => 'link',
							url  => \&get_collection_items,
							passthrough => [{
								fan => $args->{fan} || $params->{fan},
								id => $_->[2] || $_->[0],
							}]
						}
					}
				}

				if (scalar @$items) {
					push @$items, {
						name => cstring($client, $prefs->get('collectionByDate') ? 'PLUGIN_BANDCAMP_COLLECTION_BY_DATE' : 'PLUGIN_BANDCAMP_COLLECTION_BY_NAME'),
						url  => sub {
							$prefs->set('collectionByDate', !$prefs->get('collectionByDate'));
						},
						nextWindow => 'refresh'
					};

					# if we have an identity token, we're going to try to add the user's Music Feed
					if ( $prefs->get('identity_token') && $prefs->get('fan_id')
						&& ($args->{fan} || $params->{fan} || '') eq ($prefs->get('username') || '')
					) {
						splice(@$items, 1, 0, {
							type => 'playlist',
							name => cstring($client, 'PLUGIN_BANDCAMP_MUSIC_FEED'),
							url  => \&music_feed,
						})
					}
				}
			}
			elsif ( $args->{id} =~ /collection(?:_items)?/ ) {
				$items = album_list($client, \&get_item_info_by_url, {
					discography => $data->{collection},
				});
			}
			elsif ( $args->{id} =~ /wishlist(?:_items)?/ ) {
				$items = album_list($client, \&get_item_info_by_url, {
					discography => $data->{wishlist},
				});
			}
			elsif ( $args->{id} =~ /(following_bands|following_fans|followers)/ ) {
				$items = artist_list({ results => $data->{$1} });
			}

			$cb->( $items );
		},
		$params,
		$args,
	);
}

sub get_collection_items {
	my ($client, $cb, $params, $args) = @_;

	my $fan_id = $args->{fan} && $args->{fan} eq ($prefs->get('username') || '')
		? $prefs->get('fan_id')
		: '';

	$fan_id ||= $cache->get('user_id_' . $args->{fan});

	main::INFOLOG && $log->info("Using Fan ID '$fan_id' for user '$args->{fan}'");

	if ($fan_id) {

		$args->{fan_id} ||= $fan_id;
		$args->{endpoint} ||= $args->{id};

		my $items = [];

		Plugins::Bandcamp::API::get_fan_collection($client,
			sub {
				my $data = shift;

				if ( $data->{type} eq 'albums' ) {
					if (!$prefs->get('collectionByDate')) {
						$data->{items} = [ sort {
							lc($a->{title}) cmp lc($b->{title})
						} @{$data->{items}} ];
					}

					$items = album_list($client, \&get_item_info_by_url, {
						discography => $data->{items},
					},{
						dontSort => 1,
					});
				}
				elsif ( $data->{type} eq 'artists' ) {
					if (!$prefs->get('collectionByDate')) {
						$data->{items} = [ sort {
							lc($a->{name}) cmp lc($b->{name})
						} @{$data->{items}} ];
					}

					$items = artist_list({
						 results => $data->{items},
					});
				}

				$cb->($items);
			},
			$params,
			$args,
		);
	}
	else {
		get_fan_page(@_);
	}
}

sub music_feed {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::API::fan_dash_feed_updates($client,
		sub {
			my $result = shift;

			if ($result->{error}) {
				$cb->($result->{error});
				return;
			}

			my $items = track_list($client, $result, {
				no_tracknumber => 1,
				artwork        => 1,
				artist         => 1,
				album          => 1,
				params         => $params,
			});

			$cb->($items);
		},
		$params,
		{
			fan_id => $prefs->get('fan_id')
		}
	)
}

sub get_daily_shows {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_daily_list(
		sub {
			my $items = shift;

			my $shows = [];

			foreach my $show (@{$items->{daily_list}}) {
				push @$shows, {
					name  => $show->{name},
					image => $show->{cover},
					url   => \&get_daily_show,
					passthrough => [{
						url => $show->{url},
						image => $show->{cover}
					}],
				};
			}

			$cb->( $shows );
		},
	);
}

sub get_daily_show {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_daily_show(
		sub {
			my $show = shift;
			my $items = [];

			if ($show->{tracks}) {
				my $tracks = track_list($client, $show, {
					no_tracknumber => 1,
					artwork        => 1,
					artist         => 1,
				}) if $show->{tracks};

				push @$items, {
					name => cstring($client, 'PLUGIN_BANDCAMP_DAILY_SHOW_TRACKS'),
					image => $args->{image},
					items => $tracks,
					type => 'playlist',
					play => [ grep { $_ } map { $_->{play} } @$tracks ],
				};
			}

			if ($show->{albums}) {
				my $albums = album_list($client, \&get_item_info_by_url, { discography => $show->{albums} }, {
					dontSort => 1,
				});

				push @$items, @$albums;
			}

			$cb->($items);
		},
		$args
	);
}

sub get_weekly_shows {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::API::get_weekly_shows(
		sub {
			my $items = shift;

			my $shows = [];

			foreach my $show (@$items) {
				push @$shows, {
					name  => $show->{date} . ' - ' . $show->{subtitle},
					line1 => $show->{subtitle},
					line2 => $show->{date},
					image => $show->{large_art_url},
					url   => \&get_weekly_show,
					passthrough => [{
						show_id => $show->{id}
					}],
				};
			}

			$cb->( $shows );
		},
		$params,
	);
}

sub get_weekly_show {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::API::get_weekly_show(
		sub {
			my $show = shift;

			my $tracks = track_list($client, $show, {
				no_tracknumber => 1,
				artwork        => 1,
				artist         => 1,
				params         => $params,
			});

			my $items = [{
				name => $show->{description},
				type => 'textarea'
			},{
				type => 'audio',
				name => cstring($client, 'PLUGIN_BANDCAMP_WEEKLY_PODCAST'),
				url => $show->{podcast},
			},{
				type => 'playlist',
				name => cstring($client, 'PLUGIN_BANDCAMP_WEEKLY_SONGS'),
				items => $tracks,
				play  => [ grep { $_ } map { $_->{play} } @$tracks ],
			}];

			$cb->($items);
		},
		$args
	);
}

sub get_discovery {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_discovery($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, $items, {
				dontSort => 1,
			}) );
		},
		$params,
		$args,
	);
}

sub get_selling_items {
	my ($client, $cb, $params) = @_;

	# odd hack to only cache results when entering the menu, but not when drilling down from there
	$params->{use_cache} = ( ($params->{isControl} && $params->{index}) || ($params->{isWeb} && defined $params->{index}) ) ? 1 : 0;

	Plugins::Bandcamp::Scraper::get_sales_feed($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, {
				discography => $items,
			}, {
				dontSort => 1,
			}) );
		},
		$params,
	);
}

sub recently_played {
	my ($client, $cb, $params) = @_;

	my $items = [
		sort { lc($a->{title}) cmp lc($b->{title}) }
		grep { $_ }
		values %recent_plays
	];

	$items = album_list($client, \&get_item_info_by_url, {
		discography => $items
	});

	foreach (@$items) {
		my $key = $_->{passthrough}->[0]->{album_url};
		my $title = $_->{passthrough}->[0]->{title};
		$_->{itemActions} = {
			info => {
				command     => ['bandcamp', 'recentlyplayed'],
				fixedParams => { deleteMenu => $key, title => $title },
			},
		};
	}

	$cb->({
		items => $items
	});
}

sub recently_played_cli {
	my $request = shift;
	my $client = $request->client;

	# check this is the correct command.
	if ($request->isNotCommand([['bandcamp'], ['recentlyplayed']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $key = $request->getParam('deleteMenu') // $request->getParam('delete');
	my $title = $request->getParam('title');

	my $items = [];

	if (defined $request->getParam('deleteMenu')) {
		push @$items,
			{
				text => cstring($client, 'DELETE') . cstring($client, 'COLON') . ' "' . $title . '"',
				actions => {
					go => {
						player => 0,
						cmd    => ['bandcamp', 'recentlyplayed' ],
						params => {
							delete => $key
						},
					},
				},
				nextWindow => 'parent',
			},
			{
				text => cstring($client, 'PLUGIN_BANDCAMP_CLEAR_RECENTLY_PLAYED_ALBUMS'),
				actions => {
					go => {
						player => 0,
						cmd    => ['bandcamp', 'recentlyplayed' ],
						params => {
							deleteAll => 1
						},
					}
				},
				nextWindow => 'grandParent',
			};

		$request->addResult('offset', 0);
		$request->addResult('count', scalar @$items);
		$request->addResult('item_loop', $items);
	} elsif (defined $request->getParam('delete')) {
		delete $recent_plays{$key};
		_save_recently_played();
	} elsif (defined $request->getParam('deleteAll')) {
		%recent_plays = ();
		_save_recently_played();
	}
	else {
		$request->setStatusBadParams();
	}

	$request->setStatusDone;
}

sub _save_recently_played {
	# don't cache %recent_searches directly, as it's a Tie::Cache::LRU object
	$cache->set(RECENT_CACHE_KEY, { map {
		$_ => $recent_plays{$_}
	} keys %recent_plays }, RECENT_CACHE_TTL);
}

sub get_tags {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_tag_list($client,
		sub {
			my $items = shift;
			$cb->( tag_list([ grep { $_->{cloud} eq 'tags_cloud' } @$items ]) );
		},
		$params,
	);
}

sub get_locations {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_tag_list($client,
		sub {
			my $items = shift;
			$cb->( tag_list([ grep { $_->{cloud} eq 'locations_cloud' } @$items ]) );
		},
		$params,
	);
}

sub get_tag_items {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_tag_items($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, $items, $args) );
		},
		$params,
		$args,
	);
}

sub get_artist_albums {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::API::get_artist_albums($client,
		sub {
			my $items = shift;

			$cb->( album_list($client,
				sub {
					my ($client, $cb, $params, $args) = @_;
					if ($args->{album_id}) {
						get_album($client, $cb, $params, $args);
					}
					else {
						get_track($client, $cb, $params, $args);
					}
				},
				$items
			), @_ );
		},
		$params,
		$args
	);
}

sub get_album {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_album_info($client,
		sub {
			my $albumInfo = shift;

			$log->error( Data::Dump::dump($albumInfo) ) if main::INFOLOG && ref $albumInfo ne 'HASH';

			return $cb->([ {
				name => $albumInfo->{error},
				type => 'textarea',
			} ], @_) if $albumInfo->{error};

			$albumInfo->{artist} ||= $args->{artist};

			my $items = [];

			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_PAID'),
				type => 'text',
			},
			{
				name => $albumInfo->{url},
				type => 'text',
				weblink => $albumInfo->{url},
			} if $albumInfo->{url};

			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
				items => [{
					name => _cleanup_multiline($albumInfo->{about}),
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{about};

			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
				items => [{
					name => _cleanup_multiline($albumInfo->{credits}),
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{credits};

			# tell the user when there are tracks which can't be played
			if ( grep { !$_->{streaming_url} } @{$albumInfo->{tracks}} ) {
				push @$items, {
					name => cstring($client, 'PLUGIN_BANDCAMP_NOT_STREAMABLE'),
					type => 'text',
				}
			}

			push @$items, @{ track_list($client, $albumInfo, {
				params => $params,
			}) };

			$cb->( $items, @_ );
		},
		$params,
		$args
	);
}

sub get_playlist {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_playlist_page($client,
		sub {
			my $playlist = shift;

			my $items = track_list($client, { tracks => $playlist }, {
				params => $params,
			});

			$cb->( $items, @_ );
		},
		$params,
		$args
	);
}

sub get_track {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::API::get_track_info($args,
		sub {
			my $items = shift;

			$items = track_list($client, {
				tracks => [ $items ],
				artist => $args->{artist},
				url    => $args->{album_url},
				large_art_url => $args->{art_lg_url} || $args->{large_art_url},
			},{
				params => $params,
			});

			# sometimes we only want the track-information, but not the track itself
			if ($args->{notracks} && $items && ref $items eq 'ARRAY' && $items->[0] && ref $items->[0] eq 'HASH' && $items->[0]->{items}) {
				$items = $items->[0]->{items};
			}

			$cb->({
				items => $items,
			}, @_ );
		},
	)
}

sub get_item_info_by_url {
	my ($client, $cb, $params, $args) = @_;

	# we're going to grab album tracks from the albums page, as the API wouldn't give us all playable items
	if ($args->{album_url} =~ m|bandcamp\.com/album/|) {
		get_album($client, $cb, $params, $args);
	}

	# "Get more..." link
	elsif ($args->{album_url} =~ m|bandcamp\.com/+tag/.*?\?page=|) {
		get_tag_items($client, $cb, $params, {
			tag_url => $args->{album_url}
		});
	}

	# https://bandcamp.com/alynsparkes/playlist/pieces-of-eight
	elsif ($args->{url} =~ m|bandcamp\.com/.*?/playlist/|) {
		get_playlist($client, $cb, $params, $args);
	}

	# Search by tag URL
	elsif ($args->{url} =~ m|bandcamp\.com/+tag/|) {
		get_tag_items($client, $cb, $params, {
			tag_url => $args->{url}
		});
	}

	# genres inside top/recommendation etc.
	elsif ($args->{album_url} =~ m|bandcamp\.com/discover_cb\?|) {
		get_discovery($client, $cb, $params, {
			url => $args->{url}
		});
	}

	elsif (my $track_id = track_key($args->{url})) {
		$args->{track_id} = $track_id;

		get_track($client, sub {
			my $tracks = shift;
			if ($tracks && ref $tracks && $tracks->{items}) {
				return $cb->($tracks->{items});
			}

			$cb->($tracks, @_);
		}, $params, $args);
	}

	else {
		Plugins::Bandcamp::API::get_item_info_by_url($client,
			sub {
				my ($items) = shift;

				if ($items->{album_id}) {
					$args->{album_id} ||= $items->{album_id};

					get_album($client, $cb, $params, $args);
				}
				elsif ($items->{track_id}) {
					$args->{track_id}  ||= $items->{track_id};
					$args->{album_url} ||= $args->{url};

					get_track($client, sub {
						my $tracks = shift;
						if ($tracks && ref $tracks && $tracks->{items}) {
							return $cb->($tracks->{items});
						}

						$cb->($tracks, @_);
					}, $params, $args);
				}
				elsif ($items->{band_id}) {
					$args->{band_id} ||= $items->{band_id};

					get_artist_albums($client, $cb, $params, $args);
				}
				else {
					$cb->([{
						name => cstring($client, 'PLUGIN_BANDCAMP_NOT_A_URL'),
						type => 'text',
					}]);
				}
			},
			$params,
			$args,
		);
	}
}

# helper methods for metadata and trackinfo
sub metadata_provider {
	my ( $client, $url ) = @_;

	my $meta = {
		title => Slim::Music::Info::getCurrentTitle(shift),
		cover  => __PACKAGE__->_pluginDataFor('icon'),
	};

	my $key = track_key($url);
	if (my $cached = $cache->get('meta_' . $key)) {
		if ($cached->{album_url}) {
			my $song = $client->playingSong();

			# keep track of the albums we're playing
			if ( (my $title = ($cached->{album} || $cached->{title})) && (my $album_key = $cached->{album_url}) && $song && $song->track->url eq $url ) {
				$recent_plays{$album_key} = {
					title    => $title,
					url      => $cached->{album_url},
					artist   => $cached->{artist},
					image    => $cached->{image},
					album_id => $cached->{album_id},
					ts       => time(),
				};

				_save_recently_played();
			}

			$cached->{album_url} =~ s/\?pk=.*//;
		}

		my $does_scrobble = _does_scrobble($client);

		$meta = {
			title    => $cached->{title},
			artist   => $does_scrobble ? $cached->{artist} : ($cached->{album} . ($cached->{album} ? ' - ' : '') . $cached->{artist}),
			# we'll abuse the album name for the album URL to satisfy the terms of use...
			album    => $does_scrobble ? $cached->{album} : $cached->{album_url},
			duration => $cached->{duration},
			cover    => $cached->{image},
			bitrate  => "128" . Slim::Utils::Strings::string('KBPS'),
			samplesize => 16,
			samplerate => 44100,
		};
	}

	return $meta;
}

sub _does_scrobble {
	my $client = shift;

	# check whether user is scrobbling to last.fm - in this case we don't report the artist's url, but real metadata...
	if ( !defined $does_scrobble ) {
		$does_scrobble = 0;
		eval {
			$does_scrobble = preferences('plugin.audioscrobbler')->get('enable_scrobbling') && Slim::Plugin::AudioScrobbler::Plugin->condition();
		};
	}

	# scrobbling is globally disabled
	return if !$does_scrobble;

	my $_does_scrobble = $client->pluginData('does_scrobble');

	return $_does_scrobble if defined $_does_scrobble;

	$_does_scrobble = preferences('plugin.audioscrobbler')->client($client)->get('account');

	$client->pluginData( 'does_scrobble' => ($_does_scrobble ? 1 : 0) );

	return $_does_scrobble;
}

sub trackInfoMenu {
	my ( $client, undef, $track ) = @_;

	return unless $client && $track;

	my $url = $track->url;

	return unless $url && $url =~ STREAM_URL_REGEX;

	my $key = track_key($url);
	if (my $cached = $cache->get('meta_' . $key)) {
		$cached->{large_art_url} = $cached->{image};
		$cached->{notracks}      = 1;

		return {
			type => 'link',
			name => cstring($client, 'PLUGIN_FROM_BANDCAMP'),
			url  => \&get_track,
			passthrough => [ $cached ],
		};
	}

	return;
}


# methods creating the lists to be shown from our data
sub artist_list {
	my $items = shift;

	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};

	my $artists = [];
	foreach (@{$items->{results}}) {
		my $name = $_->{name};

		$name .= ' (' . string('PLUGIN_BANDCAMP_FAN') . ')' if $_->{fan};

		push @$artists, {
			name  => $name,
			line1 => $_->{offsite_url} ? $name : undef,
			line2 => $_->{offsite_url} || undef,
			url   => $_->{band_id} ? \&get_artist_albums : \&get_fan_page,
			passthrough => [{
				band_id => $_->{band_id},
				fan     => $_->{fan},
			}],
			image => $_->{art_lg_url} || $_->{large_art_url} || __PACKAGE__->_pluginDataFor('icon'),
			type  => 'link',
		}
	}

	return $artists;
}

sub tag_list {
	my $items = shift;

	my $results = [];

	$items = [ sort { uc($a->{name}) cmp uc($b->{name}) } @$items ];

	foreach my $item ( @$items ) {
		push @$results, {
			name => $item->{name},
			textkey => substr( uc($item->{name}), 0, 1 ),
			url  => \&get_tag_items,
			type => 'link',
			passthrough => [ { tag_url => $item->{url},  dontSort => 1 } ]
		}
	}

	return $results;
}

sub album_list {
	my ($client, $cb, $items, $args) = @_;

	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};

	$args ||= {};

	my $albums = [];

	my @sorted = @{$items->{discography}};

	if ( !$args->{dontSort} ) {
		@sorted = sort {
			$a->{type} eq 'link' ? 1
			: (
				$b->{type} eq 'link' ? -1
				: ( lc($a->{title} || $a->{album}) cmp lc($b->{title} || $b->{album}) )
			)
		} @sorted;
	}

	foreach (@sorted) {
		next unless ref $_ eq 'HASH';

		$_->{title} ||= $_->{album};
		$_->{type}  ||= 'playlist';

		# special case for the "get more..." item in tags lists
		$_->{title} = cstring($client, $_->{title}) if $_->{title} =~ /PLUGIN_BANDCAMP_/;

		push @$albums, {
			name  => $_->{title} . ($_->{artist} ? ' - ' . $_->{artist} : ''),
			line1 => $_->{artist} ? $_->{title} : undef,
			line2 => $_->{artist},
			url   => $cb,
			image => $_->{art_lg_url} || $_->{large_art_url} || $_->{small_art_url} || $_->{image} || __PACKAGE__->_pluginDataFor('icon'),
			passthrough => [{
				title     => $_->{title},
				album_id  => $_->{album_id},
				album_url => $_->{url},
				url       => $_->{url},
				band_id   => $_->{band_id},
				artist    => $_->{artist},
				track_id  => $_->{track_id},
				large_art_url => $_->{art_lg_url} || $_->{large_art_url} || $_->{image},
				tracks    => 1,
			}],
			type  => $_->{type} || 'playlist',
		};
	}

	return [ {
		name => cstring($client, 'EMPTY'),
		type => 'text',
	} ] if !scalar @$albums;

	return $albums;
}

sub track_list {
	my ($client, $items, $args) = @_;

	# this is ugly... for whatever reason the EN/Classic skins can't handle tracks with an items element
	my $simpleTracks = ($args->{params} && $args->{params}->{isWeb} && preferences('server')->get('skin') =~ /Classic|EN/i) ? 1 : 0;

	my $tracks = [];
	foreach my $track (@{$items->{tracks}}) {
		$track = cache_track_info($track, $items);

		my $trackinfo = [];

		push @$trackinfo, {
			name => (
				cstring($client, $track->{downloadable}
					? ($track->{downloadable} == 1 ? 'PLUGIN_BANDCAMP_FREE' : 'PLUGIN_BANDCAMP_PAID')
					: 'PLUGIN_BANDCAMP_NO_DOWNLOAD'
				)
			),
			type => 'text',
		} if ($track->{downloadable} && $track->{url} && $track->{url} =~ /^http/);

		push @$trackinfo, {
			name => $track->{url},
			type => 'text',
			weblink => $track->{url},
		} if ($track->{url} && $track->{url} =~ /^http/);

		push @$trackinfo, {
			type => 'link',
			name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $track->{artist},
			url  => \&get_artist_albums,
			passthrough => [{
				band_id => $track->{band_id}
			}]
		} if $track->{artist};

		push @$trackinfo, {
			type => 'link',
			name => $track->{album}
						? cstring($client, 'ALBUM') . cstring($client, 'COLON') . ' ' . $track->{album}
						: cstring($client, 'PLUGIN_BANDCAMP_OTHER_TRACKS'),
			url  => \&get_album,
			passthrough => [{
				album_id => $track->{album_id},
				album_url => $track->{album_url},
				tracks   => 1,
			}]
		} if $track->{album_id};

		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
			items => [{
				name => _cleanup_multiline($track->{about}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{about};

		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
			items => [{
				name => _cleanup_multiline($track->{credits}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{credits};

		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_LYRICS'),
			items => [{
				name => _cleanup_multiline($track->{lyrics}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{lyrics};

		push @$trackinfo, {
			name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . sprintf('%s:%02s', int($track->{duration} / 60), $track->{duration} % 60),
			type => 'text',
		} if $track->{duration};

		my $title = ($track->{streaming_url} ? '' : '* ') . ((defined $track->{number} && !$args->{no_tracknumber}) ? $track->{number} . '. ' : '') . $track->{title};

		# store the durable bandcamp:// URL so queued/favourited items
		# survive token expiry; streaming_url stays the "is playable" signal
		my $playUrl;
		if ($track->{streaming_url}) {
			$playUrl = track_url($track->{track_id})
				|| $track->{streaming_url};
		}

		if ($simpleTracks) {
			push @$tracks, {
				type  => $playUrl ? 'audio' : undef,
				name  => $title,
				url   => $playUrl,
				image => $args->{artwork} && ($track->{art_lg_url} || $track->{large_art_url}),
				playall => 1,
			};
		}
		else {
			push @$tracks, {
				name  => $title,
				line1 => $args->{artist} && $title,
				line2 => $args->{artist} && $track->{artist} . ($args->{album} ? ($args->{artist} ? ' - ' : '') . $track->{album} : ''),
				play  => $playUrl,
				image => $args->{artwork} && ($track->{art_lg_url} || $track->{large_art_url}),
				items => $trackinfo,
				on_select   => $playUrl ? 'play' : undef,
				playall     => 1,
				passthrough => [{
					track_id => $track->{track_id}
				}]
			};
		}
	}

	return $tracks;
}

sub _cleanup_multiline {
	my $text = shift;

	return unless defined $text;

	$text =~ s/\r\n/\n/g;
	return $text;
}

1;
