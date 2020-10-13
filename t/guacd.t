use Mojo::Base -strict;

use GuacLite::Client::Guacd;

use Test::More;

use Mojo::IOLoop;

our (@send, @received);
my $id = Mojo::IOLoop->server({address => '127.0.0.1'}, sub {
  my (undef, $stream, $id) = @_;
  $stream->on(read => sub {
    my ($stream, $bytes) = @_;
    push @received, $bytes;
    my $send = shift @send;
    $stream->write($send) if defined $send;
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
    ->then(sub { $res = shift }, sub { $err = shift})
    ->wait;
  is_deeply \@received, ['6.select,3.vnc;'];
  ok ! defined $res;
  like $err, qr/Invalid instruction encoding/;
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
    ->then(sub { $res = shift }, sub { $err = shift})
    ->wait;
  is_deeply \@received, ['6.select,3.vnc;'];
  ok ! defined $res;
  like $err, qr/Word length mismatch/;
};

subtest 'invalid response (handshake command order)' => sub {
  local @send = ('3.bad;');
  local @received;
  my $client = GuacLite::Client::Guacd->new(
    host => '127.0.0.1',
    port => $port,
  );
  my ($res, $err);
  $client->connect_p
    ->then(sub { $client->handshake_p })
    ->then(sub { $res = shift }, sub { $err = shift})
    ->wait;
  is_deeply \@received, ['6.select,3.vnc;'];
  ok ! defined $res;
  like $err, qr'Unexpected command "bad" received, expected "args"';
};

done_testing;
