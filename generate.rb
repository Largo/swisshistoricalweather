#!/usr/bin/env ruby
# frozen_string_literal: true

# Static site generator for Swiss weather-station temperature maps.
#
# Produces two self-contained pages, each a Leaflet map of Switzerland with a
# slider, from MeteoSwiss Open Government Data (collection ch.meteoschweiz.ogd-smn):
#
#   index.html   ANNUAL — absolute yearly min/max air temperature (2 m),
#                slider over years, plus the exact day each extreme occurred.
#   daily.html   DAILY  — daily min/max air temperature, slider over days.
#
# Both the yearly extremes and the "hottest/coldest day" dates are derived from
# the daily data files (tre200dx / tre200dn), so the value and its date always
# agree.
#
# Data source: https://opendatadocs.meteoswiss.ch
# Licence:     MeteoSwiss Open Data (free use, attribution appreciated).
#
# No third-party gems — Ruby standard library only, so it runs anywhere
# (including a vanilla GitHub Actions `ruby/setup-ruby` runner).
#
# Useful environment variables:
#   DAILY_YEARS    how many recent years the DAILY page covers (default: 5)
#                  (the annual page always uses the full history)
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

DAILY_YEARS  = [(ENV['DAILY_YEARS'] || '5').to_i, 1].max  # recent years on the daily page
MAX_STATIONS = ENV['MAX_STATIONS']&.to_i
THREADS      = (ENV['THREADS'] || '12').to_i
OUTPUT_DIR   = ENV['OUTPUT_DIR'] || 'public'
ROOT         = __dir__
CUTOFF_YEAR  = Time.now.utc.year - DAILY_YEARS + 1        # earliest year kept on the daily page

COL_MIN  = 'tre200dn' # daily minimum 2 m air temperature
COL_MAX  = 'tre200dx' # daily maximum 2 m air temperature
COL_MEAN = 'tre200d0' # daily mean    2 m air temperature

# ---------------------------------------------------------------------------
# HTTP helper (follows redirects, small retry loop, returns body String or nil)
# ---------------------------------------------------------------------------
def http_get(url, limit: 5)
  raise 'too many redirects' if limit.zero?

  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.open_timeout = 20
  http.read_timeout = 120

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
# Parse a daily-values CSV into { "YYYY-MM-DD" => {min:, max:, mean:} }.
# ---------------------------------------------------------------------------
def parse_daily(csv)
  out = {}
  lines = csv.split(/\r?\n/).reject(&:empty?)
  return out if lines.empty?

  header = lines.shift.split(';')
  idx = header.each_with_index.to_h
  ts_i   = idx['reference_timestamp']
  min_i  = idx[COL_MIN]
  max_i  = idx[COL_MAX]
  mean_i = idx[COL_MEAN]
  return out unless ts_i && min_i && max_i

  lines.each do |line|
    f = line.split(';')
    ts = f[ts_i]
    next unless ts

    d, m, rest = ts.split('.')           # "01.01.2026 00:00"
    next unless rest

    y = rest.split(' ').first
    date = "#{y}-#{m}-#{d}"

    mn = num(f[min_i])
    mx = num(f[max_i])
    me = mean_i ? num(f[mean_i]) : nil
    next if mn.nil? && mx.nil?

    out[date] = { min: mn, max: mx, mean: me }
  end
  out
end

# Collapse a daily hash into per-year extremes carrying the day they occurred:
# { "YYYY" => { max:, maxdate:, min:, mindate: } }
def reduce_to_annual(daily, acc)
  daily.each do |date, v|
    year = date[0, 4]
    a = (acc[year] ||= { max: nil, maxdate: nil, min: nil, mindate: nil })
    if v[:max] && (a[:max].nil? || v[:max] > a[:max])
      a[:max] = v[:max]
      a[:maxdate] = date
    end
    if v[:min] && (a[:min].nil? || v[:min] < a[:min])
      a[:min] = v[:min]
      a[:mindate] = date
    end
  end
  acc
end

def daily_url(id, kind) = "#{BASE}/#{id.downcase}/ogd-smn_#{id.downcase}_d_#{kind}.csv"

# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------
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
puts "Swiss weather map generator (daily page = last #{DAILY_YEARS} years, from #{CUTOFF_YEAR})"
puts 'Downloading station metadata…'
meta_csv = fetch_with_retries(META_STATIONS) or abort('Could not download station metadata.')
stations = parse_stations(meta_csv)
stations = stations.first(MAX_STATIONS) if MAX_STATIONS
puts "  #{stations.size} stations with coordinates."

puts "Downloading daily temperatures, full history (#{THREADS} workers)…"
queue = Queue.new
stations.each { |s| queue << s }
daily_results  = {}   # id => { date => {min,max,mean} }  (for the daily page, per DATASET)
annual_results = {}   # id => { year => {max,maxdate,min,mindate} }
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

      id = station[:id]
      recent = (body = fetch_with_retries(daily_url(id, 'recent')))     ? parse_daily(body) : {}
      hist   = (body = fetch_with_retries(daily_url(id, 'historical'))) ? parse_daily(body) : {}

      # Annual extremes always use the entire record.
      annual = {}
      reduce_to_annual(hist, annual)
      reduce_to_annual(recent, annual)

      # The daily page keeps only the last DAILY_YEARS years.
      daily_page = hist.merge(recent).select { |date, _| date[0, 4].to_i >= CUTOFF_YEAR }

      mutex.synchronize do
        daily_results[id]  = daily_page unless daily_page.empty?
        annual_results[id] = annual     unless annual.empty?
        done += 1
        print "\r  #{done}/#{stations.size}" if (done % 5).zero? || done == stations.size
      end
    end
  end
end
workers.each(&:join)
puts

abort('No temperature data downloaded — aborting.') if annual_results.empty?

# ---- Build the daily-page payload (axis = dates) --------------------------
def build_daily_payload(stations, daily_results)
  present = stations.select { |s| daily_results[s[:id]] && !daily_results[s[:id]].empty? }
  dates   = daily_results.values.flat_map(&:keys).uniq.sort
  index   = dates.each_with_index.to_h

  payload_stations = present.map do |s|
    daily = daily_results[s[:id]]
    mins = Array.new(dates.size)
    maxs = Array.new(dates.size)
    daily.each do |date, v|
      i = index[date]
      mins[i] = v[:min]
      maxs[i] = v[:max]
    end
    s.merge(min: mins, max: maxs)
  end

  base_payload(
    axis: 'date',
    title: 'Daily Temperature',
    subtitle: "Daily minimum and maximum air temperature (2&nbsp;m), last #{DAILY_YEARS} years",
    metric_note: 'Daily min / max',
    labels: dates, stations: payload_stations
  )
end

# ---- Build the annual-page payload (axis = years) -------------------------
def build_annual_payload(stations, annual_results)
  present = stations.select { |s| annual_results[s[:id]] && !annual_results[s[:id]].empty? }
  years   = annual_results.values.flat_map(&:keys).uniq.sort
  idx     = years.each_with_index.to_h

  payload_stations = present.map do |s|
    a = annual_results[s[:id]]
    maxs = Array.new(years.size); mins = Array.new(years.size)
    maxd = Array.new(years.size); mind = Array.new(years.size)
    a.each do |year, r|
      i = idx[year]
      maxs[i] = r[:max];  maxd[i] = r[:maxdate]
      mins[i] = r[:min];  mind[i] = r[:mindate]
    end
    s.merge(max: maxs, min: mins, maxdate: maxd, mindate: mind)
  end

  # Country-wide hottest and coldest single day per year.
  hottest = years.map do |year|
    best = nil
    present.each do |s|
      r = annual_results[s[:id]][year]
      next unless r && r[:max]
      best = { d: r[:maxdate], v: r[:max], s: s[:name] } if best.nil? || r[:max] > best[:v]
    end
    best
  end
  coldest = years.map do |year|
    best = nil
    present.each do |s|
      r = annual_results[s[:id]][year]
      next unless r && r[:min]
      best = { d: r[:mindate], v: r[:min], s: s[:name] } if best.nil? || r[:min] < best[:v]
    end
    best
  end

  base_payload(
    axis: 'year',
    title: 'Annual Temperature Extremes',
    subtitle: 'Absolute yearly minimum and maximum air temperature (2&nbsp;m), with the day it occurred',
    metric_note: 'Yearly min / max',
    labels: years, stations: payload_stations
  ).merge(hottest: hottest, coldest: coldest)
end

def base_payload(axis:, title:, subtitle:, metric_note:, labels:, stations:)
  {
    generated_at: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    source:       'MeteoSwiss Open Data — ch.meteoschweiz.ogd-smn',
    axis:         axis,
    title:        title,
    subtitle:     subtitle,
    metric_note:  metric_note,
    labels:       labels,
    stations:     stations
  }
end

FileUtils.mkdir_p(OUTPUT_DIR)
template = File.read(File.join(ROOT, 'templates', 'map.html.erb'))

# Annual is the default landing page (index.html); daily lives at daily.html.
annual_data = build_annual_payload(stations, annual_results)
annual_json = render_page(template, annual_data, 'index.html')

daily_data = build_daily_payload(stations, daily_results)
render_page(template, daily_data, 'daily.html')

File.write(File.join(OUTPUT_DIR, 'data.json'), annual_json)
File.write(File.join(OUTPUT_DIR, '.nojekyll'), '')

puts 'Done.'
