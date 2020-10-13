use Mojo::Base -strict;

use GuacLite::Client::Guacd;

use Test::More;

use Mojo::IOLoop;

our (@send, @received);
my $id = Mojo::IOLoop->server({address => '127.0.0.1'}, sub {
  my (undef, $stream, $id) = @_;
  $stream->on(read => sub {
    my ($stream, $bytes) = @_;
    my @instructions = split /;/, $bytes;
    for my $instruction (@instructions) {
      next unless $instruction;
      push @received, "$instruction;";
      my $send = shift @send;
      $stream->write($send) if defined $send;
    }
  });
});
my $port = Mojo::IOLoop->acceptor($id)->port;

# should test no semicolon terminator but the test just hangs :-P

subtest 'invalid response (no length)' => sub {
  local @send = ('bad;');
  local @received;
  my $client = GuacLite::Client::Guacd->new(
    host => '127.0.0.1',
    port => $port,
  );
  my ($res, $err);
  $client->connect_p
    ->then(sub { $client->handshake_p })
    ->then(sub { $res = shift }, sub { $err = shift })
    ->wait;
  is_deeply \@received, ['6.select,3.vnc;'];
  ok ! defined $res;
  like $err, qr/Handshake error: Invalid instruction encoding/;
};

subtest 'invalid response (length)' => sub {
  local @send = ('4.bad;');
  local @received;
  my $client = GuacLite::Client::Guacd->new(
    host => '127.0.0.1',
    port => $port,
  );
  my ($res, $err);
  $client->connect_p
    ->then(sub { $client->handshake_p })
    ->then(sub { $res = shift }, sub { $err = shift })
    ->wait;
  is_deeply \@received, ['6.select,3.vnc;'];
  ok ! defined $res;
  like $err, qr/Handshake error: Word length mismatch/;
};

subtest 'invalid response (handshake missing args)' => sub {
  local @send = ('3.bad;');
  local @received;
  my $client = GuacLite::Client::Guacd->new(
    host => '127.0.0.1',
    port => $port,
  );
  my ($res, $err);
  $client->connect_p
    ->then(sub { $client->handshake_p })
    ->then(sub { $res = shift }, sub { $err = shift })
    ->wait;
  is_deeply \@received, ['6.select,3.vnc;'];
  ok ! defined $res;
  like $err, qr'Handshake error: Unexpected command "bad" received, expected "args"';
};

subtest 'invalid response (handshake missing ready)' => sub {
  local @send = (
    '4.args,13.VERSION_1_1_0,8.hostname,4.port;',
    undef, undef, undef,
    '3.bad;',
  );
  local @received;
  my $client = GuacLite::Client::Guacd->new(
    host => '127.0.0.1',
    port => $port,
  );
  my ($res, $err);
  $client->connect_p
    ->then(sub { $client->handshake_p })
    ->then(sub { $res = shift }, sub { $err = shift })
    ->wait;
  is_deeply \@received, [
    '6.select,3.vnc;',
    '4.size,4.1024,3.768,2.96;',
    '5.audio;',
    '5.image;',
    '5.video;',
    '7.connect,13.VERSION_1_1_0,0.,0.;'
  ];
  ok ! defined $res;
  like $err, qr'Handshake error: Unexpected command "bad" received, expected "ready"';
};

done_testing;
