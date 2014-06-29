package PAWS;
use Dancer ':syntax';

use Pod::Abstract;
use File::Find;
use Pod::Abstract::Filter::summary;
use Pod::Abstract::Filter::overlay;
use Pod::Abstract::Filter::uncut;
use Pod::Abstract::Filter::sort;
use PodSummary;
use Pod::Abstract::BuildNode qw(node);

use Search::Elasticsearch;

our $VERSION = '0.1';

sub error_doc {
my $term = shift;
return <<EOF;

=head1 NAME

Error - Couldn't find a document called $term

=head2 DESCRIPTION

My not-so-clever search through your C<\@INC> path has failed, I guess that's no good.

EOF
}

my $elastic = undef;

sub elastic {
    my $self = shift
    return $elastic if defined $elastic;
    my $e = Search::Elasticsearch->new( nodes => [ 'localhost:9200' ] );
    $elastic = $e;
    
    return $e;
}

sub load_pa($) {
    my $term = shift;
    my $filename = $term;
    
    $filename =~ s/::/\//g;
    $filename .= '.pm' unless $filename =~ m/.pm$/;
    foreach my $path (@INC) {
        if(-r "$path/$filename") {
            $filename = "$path/$filename";
            last;
        }
    }
    
    if(-r $filename) {
        return Pod::Abstract->load_file($filename);
    } else {
        return Pod::Abstract->load_string(error_doc($term));
    }
}

sub extract_title($) {
    my $pa = shift;
    my ($name_para) = $pa->select("/head1[\@heading eq 'NAME']/:paragraph");
    if($name_para) {
        my $name = $name_para->text;

        my ($title, $sub) = split /\s+-+\s+/, $name;

        return $title, $sub;
    } else {
        return ("","")
    }
}

get '/' => sub {
    template 'index';
};

any '/search' => sub {
    my $terms = params->{terms};
    my $view = params->{view};
    
    my $pa = load_pa $terms;
    
    my ($name, $subtitle) = extract_title $pa;

    if($view eq 'summary') {
        my $summ = PodSummary->new->filter($pa);
        $_->detach foreach $summ->select('/head1[@heading eq \'NAME\']');
        $pa = $summ;
    } elsif($view eq 'uncut') {
        my $filter = Pod::Abstract::Filter::uncut->new;
        $pa = $filter->filter($pa);
    }
    if(params->{overlay}) {
        my ($overlay_list) = $pa->select("//begin[. =~ {^:overlay}](0)");
        if($overlay_list) {
            $pa = Pod::Abstract::Filter::overlay->new->filter($pa);
        }
    }
    if(params->{sort}) {
        $pa = Pod::Abstract::Filter::sort->new->filter($pa);
    }
    $name = $terms unless $name;
    
    template "display_module.tt", 
        { title => $name, sub => $subtitle, pa => $pa }, 
        {layout => undef};
};

any '/menu' => sub {
    my $terms = params->{terms};
    
    my $pa = load_pa $terms;

    my ($name, $subtitle) = extract_title $pa;

    my $summ = PodSummary->new->filter($pa);
    $_->detach foreach $summ->select('/head1[@heading eq \'NAME\']');
    
    template "display_menu.tt", 
        { title => $name, sub => $subtitle, pa => $summ }, 
        {layout => undef};
};

any '/complete' => sub {
    my $terms = params->{terms};
    
    my $e = elastic();
    my $results = $e->search(
        index => 'perldoc',
        type => 'module',
        _source => [ "title","shortdesc" ],
        body => {
            query => {
                multi_match => {
                    query => $terms,
                    fields => ["title^4", "shortdesc^2","head2^2", "pod"]
                }
            }
        }
        );
    
    my $out_mod = [ map { $_->{_source} } @{$results->{hits}{hits}} ];

    $results = $e->search(
        index => 'perldoc',
        type => 'function',
        _source => [ "title","shortdesc" ],
        body => {
            query => {
                multi_match => {
                    query => $terms,
                    fields => ["title^4", "shortdesc^2","pod"]
                }
            }
        }
        );
    my $out_fn = [ map { $_->{_source} } @{$results->{hits}{hits}} ];
        
    my $out = {
        functions => $out_fn,
        modules => $out_mod,
    };
    
    template "autocomplete.tt",
        { results => $out },
        { layout => undef };
};

any '/links' => sub {
    my $terms = params->{terms};
    
    my $pa = load_pa $terms;
    
    my %links = map { $_->link_info->{document} => $_ } grep { $_->link_info->{document} } $pa->select("//:L");

    # Find the "SEE ALSO" section and extract all the module names
    my ($see_also) = $pa->select("/head1[\@heading eq 'SEE ALSO']");
    if($see_also) {
        foreach my $text ($see_also->select("//:text")) {
            my $str = $text->body;
            my @matches = $str =~ m/(\w+\:\:[\w\:]+)/g;
            foreach my $l (@matches) {
                my $link = node->link($l);
                $links{$l} = $link;
            }
        }
    }
    my @links = map { $links{$_} } sort keys %links;
    
    template "links.tt", 
        { links => \@links }, 
        { layout => undef };
};

true;
