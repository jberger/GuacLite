package GuacLite::Plugin::Guacd;

use Mojo::Base 'Mojolicious::Plugin';

sub register {
  my ($plugin, $app, $conf) = @_;
  $app->helper('guacd.tunnel' => \&_tunnel);
}

sub _tunnel {
  my ($c, $client) = @_;

  my $tx = $c->tx;
  $tx->with_protocols('guacamole');
  $tx->with_compression;
  $tx->max_websocket_size(10485760);

  $c->on(finish => sub { $client->close; undef $c; undef $tx; undef $client });
  $client->on(close => sub { $c->finish });

  return $client->connect_p
    ->then(sub { $client->handshake_p })
    ->then(sub {
      my $id = shift;
      $client->on(instruction => sub { $c->send({text => $_[1]}) });
      $c->on(text => sub {
        my (undef, $bytes) = @_;
        # OOB messages are sent with empty instruction, for now assume its a ping
        if(substr($bytes, 0, 2) eq '0.') {
          $c->send({text => $bytes});
        } else {
          $client->write($bytes);
        }
      });
      # initiate by sending the id, except the frontend doesn't want the $
      $id =~ s/^\$//;
      my $length = length($id);
      $c->send({text => "0.,$length.$id;"});
    });
}

1;

