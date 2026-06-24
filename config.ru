# Rack config to serve the generated static site in ./public for local preview.
#
#   bundle install
#   bundle exec puma -p 8000        # then open http://localhost:8000
#
# (Run `ruby generate.rb` first so ./public exists.)

require "rack"

use Rack::Static,
    urls: [""],
    root: "public",
    index: "index.html",
    header_rules: [[:all, { "cache-control" => "no-cache" }]]

run ->(_env) { [404, { "content-type" => "text/plain" }, ["Not found\n"]] }
