use Mojo::Base -strict;

use Test::Mojo;
use Test::More;
use Time::Piece;

use CS::Command::manager;

BEGIN { $ENV{MOJO_CONFIG} = 'cs.test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;
my $db  = $app->pg->db;

$app->commands->run('reset_db');
$app->commands->run('init_db');
$app->init;

my $u = $app->model('util');
my $f = $u->format;
is $u->game_status(0 + localtime(Time::Piece->strptime('2012-10-24 13:00:00', $f))), 0,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2013-01-01 00:00:00', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2013-01-01 00:00:01', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2015-01-01 00:00:00', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2016-01-01 00:00:00', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2029-01-01 00:00:00', $f))), -1, 'right status';

# Break
$app->config->{cs}{time}{break} = ['2014-01-01 00:00:00', '2015-01-01 00:00:00'];
is $u->game_status(0 + localtime(Time::Piece->strptime('2014-01-01 00:00:00', $f))), 0, 'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2014-12-31 23:59:59', $f))), 0, 'right status';
delete $app->config->{cs}{time}{break};
is $u->game_status(0 + localtime(Time::Piece->strptime('2014-01-01 00:00:00', $f))), 1, 'right status';

is $u->team_id_by_address('127.0.2.213'),  2,     'right id';
is $u->team_id_by_address('127.0.23.127'), undef, 'right id';

my $manager = CS::Command::manager->new(app => $app);

# New round (#1)
$manager->start_round;
is $manager->round, 1, 'right round';
$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});
$app->model('score')->update;

# Runs
is $db->query('select count(*) from runs')->array->[0], 12, 'right numbers of runs';

# Down
$db->select(runs => '*', {service_id => 1, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,               'right round';
    is $_->{status}, 104,             'right status';
    is $_->{stdout}, "some error!\n", 'right stdout';
    is $_->{result}{check}{stderr},    '',              'right stderr';
    is $_->{result}{check}{stdout},    "some error!\n", 'right stdout';
    is $_->{result}{check}{exception}, '',              'right exception';
    is $_->{result}{check}{timeout},   0,               'right timeout';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Up
$db->select(runs => '*', {service_id => 2, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 101, 'right status';
    is $_->{stdout}, '',  'right stdout';
    for my $step (qw/check put get_1/) {
      is $_->{result}{$step}{stderr},    '',  'right stderr';
      is $_->{result}{$step}{stdout},    911, 'right stdout';
      is $_->{result}{$step}{exception}, '',  'right exception';
      is $_->{result}{$step}{timeout},   0,   'right timeout';
    }
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Timeout
$db->select(runs => '*', {service_id => 4, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 104, 'right status';
    is $_->{stdout}, '',  'right stdout';
    is $_->{result}{check}{stderr},      '',           'right stderr';
    is $_->{result}{check}{stdout},      '',           'right stdout';
    like $_->{result}{check}{exception}, qr/timeout/i, 'right exception';
    is $_->{result}{check}{timeout},     1,            'right timeout';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# SLA
is $db->query('select count(*) from sla')->array->[0], 12, 'right sla';

# FP
is $db->query('select count(*) from flag_points')->array->[0], 12, 'right fp';

# Flags
is $db->query('select count(*) from flags where service_id != 3')->array->[0], 1, 'right numbers of flags';
$db->query('select * from flags where service_id != 3')->hashes->map(
  sub {
    is $_->{round},  1,                'right round';
    is $_->{id},     911,              'right id';
    like $_->{data}, qr/[A-Z\d]{31}=/, 'right flag';
  }
);

# New round (#2)
$manager->start_round;
is $manager->round, 2, 'right round';
$app->model('score')->update;

# Stolen flags
my ($data, $flag_data);

my $flag_cb = sub { $data = $_[0] };
$app->model('flag')->accept(2, 'flag', $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/invalid flag/, 'right error';

$flag_data = $db->select(flags => 'data', {team_id => 2})->hash->{data};
$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/flag is your own/, 'right error';

$flag_data = $db->select(flags => 'data', {team_id => 1})->hash->{data};
$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 1, 'right status';
is $db->select(stolen_flags => 'data', {team_id => 2})->hash->{data}, $flag_data, 'right flag';

$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/you already submitted this flag/, 'right error';

$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});

# SLA
is $db->query('select count(*) from sla')->array->[0], 24, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 2, round => 1})->hash;
is $data->{successed}, 1, 'right sla';
is $data->{failed},    0, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 1, round => 1})->hash;
is $data->{successed}, 0, 'right sla';
is $data->{failed},    1, 'right sla';

# FP
is $db->query('select count(*) from flag_points')->array->[0], 24, 'right fp';

# New round (#3)
$manager->start_round;
is $manager->round, 3, 'right round';
$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});
$app->model('score')->update;

# SLA
is $db->query('select count(*) from sla')->array->[0], 36, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 2, round => 2})->hash;
is $data->{successed}, 2, 'right sla';
is $data->{failed},    0, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 1, round => 2})->hash;
is $data->{successed}, 0, 'right sla';
is $data->{failed},    2, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 3, round => 2})->hash;
is $data->{successed} + $data->{failed}, 2, 'right sla';

# FP
is $db->query('select count(*) from flag_points')->array->[0], 36, 'right fp';

$app->model('score')->update(3);

# API
$t->get_ok('/api/info')
  ->json_has('/start')
  ->json_has('/end')
  ->json_has('/services')
  ->json_has('/teams')
  ->json_has('/teams/1/host')
  ->json_has('/teams/1/id')
  ->json_has('/teams/1/name')
  ->json_has('/teams/1/network');

$t->get_ok('/scoreboard.json')
  ->json_has('/round')
  ->json_has('/scoreboard')
  ->json_has('/scoreboard/0/d')
  ->json_has('/scoreboard/0/round')
  ->json_has('/scoreboard/0/host')
  ->json_has('/scoreboard/0/team_id')
  ->json_has('/scoreboard/0/score')
  ->json_has('/scoreboard/0/old_score')
  ->json_has('/scoreboard/0/n')
  ->json_has('/scoreboard/0/name')
  ->json_has('/scoreboard/0/services')
  ->json_has('/scoreboard/0/old_services')
  ->json_has('/scoreboard/0/services/0/stdout')
  ->json_has('/scoreboard/0/services/0/id')
  ->json_has('/scoreboard/0/services/0/sflags')
  ->json_has('/scoreboard/0/services/0/flags')
  ->json_has('/scoreboard/0/services/0/sla')
  ->json_has('/scoreboard/0/services/0/fp')
  ->json_has('/scoreboard/0/services/0/status');

$t->get_ok('/history/scoreboard.json')
  ->json_has('/0/round')
  ->json_has('/0/scoreboard')
  ->json_has('/0/scoreboard/0/id')
  ->json_has('/0/scoreboard/0/score')
  ->json_has('/0/scoreboard/0/services')
  ->json_has('/0/scoreboard/0/services/0/sflags')
  ->json_has('/0/scoreboard/0/services/0/flags')
  ->json_has('/0/scoreboard/0/services/0/fp')
  ->json_has('/0/scoreboard/0/services/0/status');

done_testing;
