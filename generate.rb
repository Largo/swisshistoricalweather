#!/usr/bin/env ruby
# frozen_string_literal: true

# Static site generator for Swiss weather-station temperature maps.
#
# Produces two self-contained pages, each a Leaflet map of Switzerland with a
# slider, from MeteoSwiss Open Government Data (collection ch.meteoschweiz.ogd-smn):
#
#   index.html   daily min/max air temperature (2 m), slider over days
#   annual.html  absolute yearly min/max air temperature, slider over years
#
# Data source: https://opendatadocs.meteoswiss.ch
# Licence:     MeteoSwiss Open Data (free use, attribution appreciated).
#
# No third-party gems — Ruby standard library only, so it runs anywhere
# (including a vanilla GitHub Actions `ruby/setup-ruby` runner).
#
# Useful environment variables:
#   SMN_DATASET    recent | historical | both   (daily granularity; default: recent)
#   MAX_STATIONS   limit number of stations (for quick local tests)
#   THREADS        parallel download workers (default: 12)
#   OUTPUT_DIR     output directory (default: public)

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'fileutils'
require 'erb'

BASE          = 'https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn'
META_STATIONS = "#{BASE}/ogd-smn_meta_stations.csv"

DATASET      = (ENV['SMN_DATASET'] || 'recent').downcase   # recent | historical | both
MAX_STATIONS = ENV['MAX_STATIONS']&.to_i
THREADS      = (ENV['THREADS'] || '12').to_i
OUTPUT_DIR   = ENV['OUTPUT_DIR'] || 'public'
ROOT         = __dir__

# Daily parameters
COL_DMIN  = 'tre200dn' # daily minimum 2 m air temperature
COL_DMAX  = 'tre200dx' # daily maximum 2 m air temperature
COL_DMEAN = 'tre200d0' # daily mean    2 m air temperature
# Yearly parameters
COL_YMIN  = 'tre200yn' # absolute annual minimum 2 m air temperature
COL_YMAX  = 'tre200yx' # absolute annual maximum 2 m air temperature
COL_YMEAN = 'tre200y0' # annual mean             2 m air temperature

# ---------------------------------------------------------------------------
# HTTP helper (follows redirects, small retry loop, returns body String or nil)
# ---------------------------------------------------------------------------
def http_get(url, limit: 5)
  raise 'too many redirects' if limit.zero?

  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.open_timeout = 20
  http.read_timeout = 60

  res = http.get(uri.request_uri, 'User-Agent' => 'swiss-weather-map-generator')
  case res
  when Net::HTTPSuccess     then res.body
  when Net::HTTPRedirection then http_get(res['location'], limit: limit - 1)
  when Net::HTTPNotFound,
       Net::HTTPForbidden   then nil
  else nil
  end
rescue StandardError => e
  warn "  ! fetch failed #{url}: #{e.class}: #{e.message}"
  nil
end

def fetch_with_retries(url, attempts: 3)
  attempts.times do |i|
    body = http_get(url)
    return body if body
    sleep(0.5 * (i + 1)) if i < attempts - 1
  end
  nil
end

def num(str)
  return nil if str.nil? || str.strip.empty?

  Float(str)
rescue ArgumentError
  nil
end

# ---------------------------------------------------------------------------
# Parse the station metadata CSV (semicolon separated, ISO-8859-1 encoded).
# ---------------------------------------------------------------------------
def parse_stations(csv)
  csv = csv.encode('UTF-8', 'ISO-8859-1', invalid: :replace, undef: :replace)
  lines = csv.split(/\r?\n/).reject(&:empty?)
  header = lines.shift.split(';')
  idx = header.each_with_index.to_h

  lines.filter_map do |line|
    f = line.split(';')
    lat = f[idx['station_coordinates_wgs84_lat']].to_f
    lon = f[idx['station_coordinates_wgs84_lon']].to_f
    next if lat.zero? || lon.zero?

    {
      id:     f[idx['station_abbr']],
      name:   f[idx['station_name']],
      canton: f[idx['station_canton']],
      lat:    lat.round(5),
      lon:    lon.round(5),
      alt:    f[idx['station_height_masl']].to_f.round
    }
  end
end

# ---------------------------------------------------------------------------
# Parse a values CSV into { key => {min:, max:, mean:} }.
# key_mode: :date -> "YYYY-MM-DD"  |  :year -> "YYYY"
# ---------------------------------------------------------------------------
def parse_values(csv, min_col, max_col, mean_col, key_mode)
  out = {}
  lines = csv.split(/\r?\n/).reject(&:empty?)
  return out if lines.empty?

  header = lines.shift.split(';')
  idx = header.each_with_index.to_h
  ts_i   = idx['reference_timestamp']
  min_i  = idx[min_col]
  max_i  = idx[max_col]
  mean_i = idx[mean_col]
  return out unless ts_i && min_i && max_i

  lines.each do |line|
    f = line.split(';')
    ts = f[ts_i]
    next unless ts

    # "01.01.2026 00:00" -> d=01 m=01 y=2026
    d, m, rest = ts.split('.')
    next unless rest

    y = rest.split(' ').first
    key = key_mode == :year ? y : "#{y}-#{m}-#{d}"

    mn = num(f[min_i])
    mx = num(f[max_i])
    me = mean_i ? num(f[mean_i]) : nil
    next if mn.nil? && mx.nil?

    out[key] = { min: mn, max: mx, mean: me }
  end
  out
end

# Which daily files to pull for a station, given the SMN_DATASET setting.
def daily_urls(id)
  a = id.downcase
  files = []
  files << "#{BASE}/#{a}/ogd-smn_#{a}_d_recent.csv"     if %w[recent both].include?(DATASET)
  files << "#{BASE}/#{a}/ogd-smn_#{a}_d_historical.csv" if %w[historical both].include?(DATASET)
  files
end

def yearly_url(id)
  a = id.downcase
  "#{BASE}/#{a}/ogd-smn_#{a}_y.csv"
end

# ---------------------------------------------------------------------------
# Build a page payload: a global label axis + per-station aligned arrays.
# results: { station_id => { key => {min:,max:,mean:} } }
# ---------------------------------------------------------------------------
def build_payload(stations, results, axis:, title:, subtitle:, metric_note:, params:)
  present = stations.select { |s| results[s[:id]] && !results[s[:id]].empty? }
  labels  = results.values.flat_map(&:keys).uniq.sort
  index   = labels.each_with_index.to_h

  station_payload = present.map do |s|
    data = results[s[:id]]
    mins = Array.new(labels.size)
    maxs = Array.new(labels.size)
    data.each do |key, v|
      i = index[key]
      mins[i] = v[:min]
      maxs[i] = v[:max]
    end
    s.merge(min: mins, max: maxs)
  end

  {
    generated_at: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    source:       'MeteoSwiss Open Data — ch.meteoschweiz.ogd-smn',
    axis:         axis,              # "date" | "year"
    title:        title,
    subtitle:     subtitle,
    metric_note:  metric_note,
    params:       params,
    labels:       labels,
    stations:     station_payload
  }
end

def render_page(template_src, data, out_file)
  data_json = JSON.generate(data)
  html = ERB.new(template_src, trim_mode: '-').result_with_hash(data_json: data_json, data: data)
  File.write(File.join(OUTPUT_DIR, out_file), html)
  kb = (data_json.bytesize / 1024.0).round
  puts "  wrote #{OUTPUT_DIR}/#{out_file} (#{data[:stations].size} stations, " \
       "#{data[:labels].size} #{data[:axis]}s, #{kb} KB)"
  data_json
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
puts "Swiss weather map generator (daily dataset=#{DATASET})"
puts 'Downloading station metadata…'
meta_csv = fetch_with_retries(META_STATIONS) or abort('Could not download station metadata.')
stations = parse_stations(meta_csv)
stations = stations.first(MAX_STATIONS) if MAX_STATIONS
puts "  #{stations.size} stations with coordinates."

puts "Downloading daily + yearly temperatures (#{THREADS} workers)…"
queue = Queue.new
stations.each { |s| queue << s }
daily_results  = {}
yearly_results = {}
mutex = Mutex.new
done  = 0

workers = Array.new([THREADS, stations.size].min) do
  Thread.new do
    loop do
      station = begin
        queue.pop(true)
      rescue ThreadError
        break
      end

      # Daily values (current year and/or historical)
      daily = {}
      daily_urls(station[:id]).each do |url|
        body = fetch_with_retries(url)
        daily.merge!(parse_values(body, COL_DMIN, COL_DMAX, COL_DMEAN, :date)) if body
      end

      # Yearly absolute values (full archive)
      yearly = {}
      body = fetch_with_retries(yearly_url(station[:id]))
      yearly = parse_values(body, COL_YMIN, COL_YMAX, COL_YMEAN, :year) if body

      mutex.synchronize do
        daily_results[station[:id]]  = daily  unless daily.empty?
        yearly_results[station[:id]] = yearly unless yearly.empty?
        done += 1
        print "\r  #{done}/#{stations.size}" if (done % 5).zero? || done == stations.size
      end
    end
  end
end
workers.each(&:join)
puts

abort('No temperature data downloaded — aborting.') if daily_results.empty? && yearly_results.empty?

FileUtils.mkdir_p(OUTPUT_DIR)
template = File.read(File.join(ROOT, 'templates', 'map.html.erb'))

# --- Daily page ------------------------------------------------------------
daily_data = build_payload(
  stations, daily_results,
  axis: 'date',
  title: 'Daily Temperature',
  subtitle: 'Daily minimum and maximum air temperature (2&nbsp;m) per station',
  metric_note: 'Daily min / max',
  params: { min: COL_DMIN, max: COL_DMAX, mean: COL_DMEAN }
)
daily_json = render_page(template, daily_data, 'index.html')

# --- Annual page -----------------------------------------------------------
annual_data = build_payload(
  stations, yearly_results,
  axis: 'year',
  title: 'Annual Temperature Extremes',
  subtitle: 'Absolute yearly minimum and maximum air temperature (2&nbsp;m) per station',
  metric_note: 'Absolute yearly min / max',
  params: { min: COL_YMIN, max: COL_YMAX, mean: COL_YMEAN }
)
render_page(template, annual_data, 'annual.html')

# Also drop the daily JSON as a standalone file, and disable Jekyll on Pages.
File.write(File.join(OUTPUT_DIR, 'data.json'), daily_json)
File.write(File.join(OUTPUT_DIR, '.nojekyll'), '')

puts 'Done.'
