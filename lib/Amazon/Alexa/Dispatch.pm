package Amazon::Alexa::Dispatch;
use strict;
use warnings;
use JSON;
use Net::OAuth2;
use Time::Piece;
use URI::Escape;

my $me = 'Amazon::Alexa::Dispatch';

=head1 NAME

Amazon::Alexa::Dispatch - Perl extensions for creating an Alexa skill

=head1 SYNOPSIS

  use Amazon::Alexa::Dispatch;

  Amazon::Alexa::Dispatch->new({
      dispatch=>[
          'Amazon::Alexa::SomePlugin',
          'Amazon::Alexa::AnotherPlugin'
      ],
      skillName=>'YourSkillName',
    })->dispatch_CGI;

=head1 DESCRIPTION

  A Perl module which provides a simple and lightweight interface to the Amazon
  Alexa Skills Kit

=head1 METHODS

  A list of methods available

=head2 new

  Create a new instance of Disptach.

=over

=over

=item skillName

  The name you wish to give this Alexa skill.  Used when displaying documentation.

=item dispatch [array]

  Any additional plugins you wish to dispatch to.  If you do not include any plugins
  then this module will only be able to perform Hello requests.

  If multiple plugins share the same method calls, the one listed first will be used.

=item token_dispatch

  By default uses the first plugin in your list.  If you wish to use a different
  plugin for token creation/authentication then list that module here.

=back

=back

=cut

sub new {
    my $class = shift;
    my $args = shift;
    my $dispatch = $args->{'dispatch'};
    $dispatch = [$dispatch] if $dispatch && !ref $dispatch;
    push @$dispatch, 'Amazon::Alexa::Dispatch';
    my $node = {
        skillName => $args->{'skillName'} // 'SKILL',
        dispatch => $dispatch,
        token_dispatch => $args->{'token_dispatch'} || $dispatch->[0],
    };
    foreach my $d (@$dispatch) {
        eval "require $d"; ## no critic
        die "[$me] Skill plugin must support alexa_authenticate_token\n" unless $d->can('alexa_authenticate_token');
        die "[$me] Skill plugin must support alexa_configure\n" unless $d->can('alexa_configure');
        my $h = $d->alexa_configure;
        die "[$me] Skill plugin must support alexa_configure\n" unless ref $h eq 'HASH';
        $d = {
            %$h,
            module => $d,
        };
    }
    return bless $node, $class;
}

sub _run_method {
    my $self = shift;
    my $json = shift;
    my $module;
    my $method = $json->{'request'}->{'intent'}->{'name'};
    my $resp;
    my $ok = eval {
        $module = $self->_find_module($method);
        1;
    };
    my $e = $@; # should only happen if they have a bad intent schema on amazon
    $resp = $self->_msg_to_hash('Sorry, I could not find that intent for this skill.',$e) if $e || !$ok || !$module;
    if (!$resp) {
        $ok = eval {
            $method = ($module->{'intentPrefix'}//'').$method;
            $self->_authenticate_token($module,$method,$json->{'session'}->{'user'}->{'accessToken'},$json->{'request'}->{'timestamp'});
        };
        $e = $@;
        $resp = $self->_msg_to_hash('Failed to authenticate.  Please use the Alexa mobile app to re link this skill.',$e) if $e || !$ok;
        $resp = $module->{'module'}->$method($self->{'user'},$json) unless $resp;
    }
    $self->_print_json($resp);
}

sub _find_module {
    my $self = shift;
    my $method = shift;
    foreach my $module (@{$self->{'dispatch'}}) {
        return $module if $module->{'module'}->can(($module->{'intentPrefix'}//'').$method);
    }
    die "[$me] Unknown intent $method\n" unless $self->{'dispatch'}->[0]->{'module'}->can($method);
}

sub _print_json {
    my $self = shift;
    my $data = shift;
    my $jsonp = JSON::XS->new;
    $jsonp->pretty(1);
    my $pretty_json = $jsonp->encode($self->_msg_to_hash($data));
    print "Content-Type:text/plain;charset=UTF-8\n\n",$pretty_json;
}

sub _msg_to_hash {
    my $self = shift;
    my $msg = shift;
    my $e = shift;
    warn $e if $e;
    return $msg if ref $msg eq 'HASH';
    return {
        version => '1.0',
        sessionAttributes=>{},
        response=>{
            outputSpeech => {
                type => 'PlainText',
                text => "$msg",
            },
            shouldEndSession => JSON::true,
        },
    };
}

sub _authenticate_token {
    my $self = shift;
    my $module = shift;
    my $method = shift;
    my $p = shift;
    my $t = shift || die "[$me] Missing request timestamp, try again later\n";
    $t =~ s/Z$/ +0000/;
    my $dateformat = '%Y-%m-%dT%H:%M:%S %z';
    my $date1 = eval{ Time::Piece->strptime($t, $dateformat)} || die "[$me] Invalid request timestamp, try again later\n";
    my $d_txt = `/bin/date +'$dateformat'`;
    chomp($d_txt);
    my $date2 = eval{ Time::Piece->strptime($d_txt, $dateformat) } || die "[$me] Could not read local time, try again later\n";
    die "[$me] Request too old, try again later\n" if abs($date1->strftime('%s') - $date2->strftime('%s')) > 500;
    $self->{'user'} = $module->{'module'}->alexa_authenticate_token($method,$p);
    die "[$me] Please open the Alexa $self->{'skillName'} skill to re link your account, then try again.\n" unless $self->{'user'};
    1;
}

=head2 dispatch_CGI

  Handles processing of calls in an apache or mod_perl environment.

  Can handle 3 types of calls
    1) Linking your Alexa skill
    2) Displaying a generic help page
    3) Processing an alexa skill request

=over

=over

=item helpPage

  Valid values are
    1) full - (default) displays a large help page.  Useful to for setting up your skill
    2) none - simply displays an empty HTML page
       on the alexa developer site.
    3) partial - (TODO) A simple blurp about your skill

  New users will likely want assistance with the "full" setting.  However once you have
  configured your alexa skill we recommend setting helpPage to "none" or "partial"

=back

=back

=cut

sub dispatch_CGI {
    my $self = shift;
    my $args = shift;
    require CGI;
    my $cgi = CGI->new;
    my $json_raw = $cgi->param('POSTDATA');
    if ($cgi->param('response_type') && $cgi->param('response_type') eq 'token'
        && $cgi->param('redirect_uri')
        && $cgi->param('state')
        && $cgi->param('client_id')
    ) {
        my $uri = $cgi->param('redirect_uri');
        my $state = $cgi->param('state');
        my $token = $self->{'token_dispatch'}->alexa_create_token();
        if ($token) {
            my $full = $uri.'#token_type=Bearer&access_token='.uri_escape($token).'&state='.uri_escape($state);
            print &CGI::header(-'status'=>302,-'location'=>$full,-'charset'=>'UTF-8',-'Pragma'=>'no-cache',-'Expires'=>'-2d');
        } else {
            # should never get here if the alexa_create_token was built properly.
            print "Content-Type:text/html\n\n";
            print "Something went wrong.  Please try to link the skill again\n";
        }
    } elsif ($json_raw) {
        my $json_data= eval { decode_json($json_raw); };
        $self->_run_method($json_data);
    } elsif (($args->{'helpPage'}//'') eq 'none') {
        print "Content-Type:text/html\n\n";
    } else {
        print "Content-Type:text/html\n\n";
        if (!$self->{'token_dispatch'}->can('alexa_create_token')) {
            print '<font color=red>WARNING</font>: Your skill does not support auto-linking with alexa.  Missing "alexa_create_token" method.<br>';
        }
        print '<h1>Contents:</h1><ol>
<li><a href="#schema">Intent Schema</a>
<li><a href="#utterances">Sample Utterances</a>
<li><a href="#intents">Intents</a>
</ol>
You can configure your skill with the following data<br>';

        my $methodList = {};
        foreach my $module (@{$self->{'dispatch'}}) {
            my $m = quotemeta($module->{'intentPrefix'}//'');
            if ($m) {
                no strict 'refs'; ## no critic
                my @methods = grep { $_ =~ /^$m/ && $_ !~ /__meta$/ && $module->{'module'}->can($_) } sort keys %{$module->{'module'}.'::'};
                use strict 'refs';
                foreach my $method (@methods) {
                    my $intent = $method;
                    my $meta = $method.'__meta';
                    $intent =~ s/^$m//;
                    $method = {method=>$method,intent=>$intent};
                    $method->{'meta'} = $module->{'module'}->$meta() if $module->{'module'}->can($meta);
                }
                $methodList->{$module->{'module'}} = \@methods;
            } else {
                $methodList->{$module->{'module'}} = [{errors=>"intentPrefix must exist to list methods"}];
            }
        }

        print '<a name="schema"><h1>Intent Schema:</h1><textarea cols=100 rows=10>{"intents": ['."\n";
        my $out = '';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                my $schema = {intent=>$i->{'intent'}};
                $schema->{'slots'} = $i->{'meta'}->{'slots'} if $i->{'meta'}->{'slots'};
                $out .= &CGI::escapeHTML('    '.to_json($schema).",\n");
            }
        };
        chop($out);chop($out);
        print $out."  ]\n}</textarea><br>";

        print '<a name="utterances"><h1>Sample Utternaces:</h1><textarea cols=100 rows=10>';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                foreach my $u (@{$i->{'meta'}->{'utterances'}}) {
                    print &CGI::escapeHTML($i->{'intent'}.' '.$u)."\n";
                }
            }
        };
        print '</textarea><br>';

        print '<a name="intents"><h1>Intents:</h1>';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                print '<h2>'.&CGI::escapeHTML($i->{'intent'}).'</h2>Interaction:<ul>';
                foreach my $u (@{$i->{'meta'}->{'utterances'}}) {
                    print '<li>Alexa tell '.&CGI::escapeHTML($self->{'skillName'}).' to '.$u;
                }
                print '</ul>';
            }
        };
    }
}

=head2 alexa_configure

  All dispatch plugins should have this method.  It's used by the new plugin to configure
  the dispatcher.

=over

=over

=item intentPrefix

  Recommended value is alexa_intent_, but anything can be used.

  This value will be prepended to all intent requests coming from Alexa.  For example
  if you have an intent called HelloIntent then the distpacher would look for a method
  similar to Amazon::Alexa::Plugin->alexa_intent_HelloIntent()

=back

=back

=cut

sub alexa_configure {{
    intentPrefix => 'alexa_intent_',
}}

=head2 alexa_create_token

  Should return nothing if no token was created.  Any other value will be assumed to
  be the token to send back to Amazon.

=over

=over

=item ARGS are a TODO, cleanup is required to make this work better first

=back

=back

=cut

sub alexa_create_token {
    die "[$me] Not supported\n";
}

=head2 alexa_authenticate_token( $method, $token )

  Used by the dispatcher to grant access.  Two arguments are passed in.

  If authentication is successful this method should return the "username" that is valid
  within your environment.

  If authentication fails, this method should die.

=over

=over

=item method

  This is the name of the action to be performed.  For example HelloIntent.

=item token

  The token provided by Amazon Alexa.

=back

=back

=cut

sub alexa_authenticate_token {
    return 'nobody';
}

=head2 alexa_intent_HelloIntent( $user, $json )

  A sample intent action that an Alexa skill can perform.  All skills will be passed
  two values.  A user value (come from your alexa_authenticate_token) and the raw
  json data from Amazon.

  The return value should be the text that you wish Alexa to say in response to the
  skill request.

=cut

sub alexa_intent_HelloIntent {
    return "Alexa dispatcher says hello\n";
}

=head2 alexa_intent_HelloIntent__meta

 Basic meta information about your skill.  This will be used by the automatic
 documentation to make it easier for others to create their own skills using your
 plugin

=cut

sub alexa_intent_HelloIntent__meta {
    return {
        utterances => [
            'hello',
        ],
        # slots => [{name=>"someName",type=>"someType"},{name=>"anotherName",type=>"anotherType"}]
    }
}

1;