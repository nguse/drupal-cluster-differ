# Drupal Cluster Differ

Drupal Cluster Differ is a web crawler for Drupal websites which designed to compare output across various nodes (e.g. http cache/app server) and ensure the output is identical.

Some scrubbing is done automatically for content which is expected to be different for page requests from Drupal, things like form_build_id, etc.  These differences were ones I experienced, if you know of or find other differences please let me know and I can add it to the normalize_content function (or feel free to make a pull request).

## How to read the output summary

The output from this script will include a summary at the end listing any errors (e.g. Request timeout) and any mismatches between backends.

Note: The backends/starting URL for this was using the examples on this page.

```
--------------------------------------------------------
---------------------- Summary -------------------------
--------------------------------------------------------

------------ Mismatches ------------
Mismatch at http://www.foo.com/page1, backend: varnish2.foo.com
Mismatch at http://www.foo.com/page2, backend: drupal1.foo.com
Mismatch at http://www.foo.com/page2, backend: drupal2.foo.com
Mismatch at http://www.foo.com/page3, backend: drupal1.foo.com
```

What an output like this might tell you:

- varnish2.foo.com has an old cached copy of http://www.foo.com/page1 (varnish1 and varnish2 do not match, but drupal1 and drupal2 match varnish1)
- varnish1.foo.com and varnish2.foo.com have old copies of http://www.foo.com/page2 (varnish1 and varnish2 match, but drupal1 and drupal2 do not match varnish1)
- drupal1.foo.com and drupal2.foo.com may be outputting different content (assuming varnish1 and varnish2 both point to drupal1 and drupal2 for backends) for http://www.foo.com/page3 (varnish1, varnish2, and drupal2 match, but varnish1 and drupal1 do not match)

## How to configure this

Numerous configuration options are available for this script; use your favorite editor to edit the diff.pl script to edit these options.

### Crawler

The Crawler works by starting with a given set of starting URLs, then parsing the content for URLs matching the url_matcher regular expression, then parsing and comparing the output from those matching files.

#### Starting URLs

These URLs are the entry points the crawler starts at to start crawling and comparing content.

```
my @starting_urls = (
	'http://www.foo.com',
);
```

#### Backends

These are the backends we'll be making requests against to compare the output.

Note: The first listed backend is the "source" against which all other backends are compared to. This is important as it is the basis for the diff/mismatch outputs!

```
my @backends = (
	"varnish1.foo.com",
	"varnish2.foo.com",
	"drupal1.foo.com",
	"drupal2.foo.com",
);
```

#### URL Matcher

The URL matcher is a regular expression; when the crawler parses the page content and scrapes the links in a page it will compare the URL with this regular expression. When a matching link is found, it is added to the queue to request/compare/parse for additional URLs.

```my $url_matcher = '^https?:\/\/www\.foo\.com';```

#### Max Spider Depth

The max depth controls how many levels deep to spider.

Only compare content of the initial starting URLs:
```my $max_depth = 0;```

Compare content of the initial starting URLs and pages it links to directly:
```my $max_depth = 1;```

Compare content of the initial starting URLs and pages it links to directly and pages those link to directly:
```my $max_depth = 2;```

### Output

#### Output a line for every request made

This setting will result in the differ outputting a line for every request made with the following format:
```
<URL> <HTTP Status Code> <Backend> <md5 sum of the page content>
http://www.foo.com/node/12584 200 backend1.foo.com 11129c67cf1cd61ce9a031920c7c9b28
```

```my $quiet = 1;```

#### Output the diff of page request results

Setting this will trigger the script to output (or not output) a diff format of the differences noticed between requests. By default this is enabled.

```my $show_diff = 1;```

## How to run this

Note: All the below commands assume you have a terminal opened to the directory where this code is checked out to.

#### Docker

Using Docker is the easiest method to run this (you don't need to install any perl dependencies on your host).

```docker build . --tag drupal-cluster-differ```

```docker run --volume="$PWD:/usr/src/myapp/" drupal-cluster-differ```


#### Native

If you wish to run this natively on your workstation, install the perl dependencies with cpanm:

```cpanm Mojo::UserAgent Text::Diff Data::Dumper Data::TreeDumper Time::HiRes```

Then you can run the script:

```./differ.pl```
