#! /usr/bin/env ruby

# CONFIGS
SERVER = 'irc.freenode.net'
PORT   = 6697
SSL    = true
CHAN   = '##distro'
NAME   = 'issuebot'

USER       = 'distro'
CHECK_TIME = 60
LOGSTDOUT  = true
LOGFILE    = false # or File.join(ENV['HOME'], '.issuebot.log')
# END

if RUBY_VERSION !~ /^(1\.9)/
  require 'rubygems'
  require 'openssl/nonblock'
end

require 'cgi'
require 'yaml'
require 'json'
require 'openssl'
require 'net/http'

class IssueFetcher
  def initialize (user, repo, cache=nil)
    @user, @repo, @cache = user, repo, cache
    self.fetch unless @cache
  end

  def issues
    @cache
  end

  def fetch
    ouri = URI.parse("http://github.com/api/v2/yaml/issues/list/#@user/#@repo/open")
    curi = URI.parse("http://github.com/api/v2/yaml/issues/list/#@user/#@repo/closed")

    @cache = YAML.load(Net::HTTP.get(ouri))['issues'] + YAML.load(Net::HTTP.get(curi))['issues']
  end
end

class IssueDiff
  def initialize (user, repo, cache=nil, ignore=nil)
    @user, @repo, @ignore = user, repo, ignore || []
    @fetcher = IssueFetcher.new(user, repo, cache)
    @old = @fetcher.issues
  end

  def ignore(id)
    @ignore << id.to_i
    true
  end

  def unignore(id)
    @ignore.delete(id.to_i)
    true
  end

  def ignoring; @ignore.dup; end

  def old
    @old.select {|x|
      !@ignore.include?(x['number'])
    }
  end

  def new
    (@new ||= @fetcher.fetch).select {|x|
      !@ignore.include?(x['number'])
    }
  end

  def issues
    @fetcher.issues
  end

  def refresh
    if @new ||= nil
      @old, @new = @new, @fetcher.fetch
    else
      new
    end
    self
  end

  def created
    numbers = new.map {|issue| issue['number'] } - old.map {|issue| issue['number'] }
    new.select {|x|
      numbers.include?(x['number'])
    } - removed
  end

  def removed
    numbers = old.map {|issue| issue['number'] } - new.map {|issue| issue['number'] }
    new.select {|x|
      numbers.include?(x['number'])
    }
  end

  def commented
    common_zip.select {|(o, n)|
      o['comments'].to_i < n['comments'].to_i
    }.map {|(o, n)|
      n.dup.tap {|res|
        res['comments'] = self.comments(n['number']).reverse[0, n['comments'].to_i - o['comments'].to_i]
      }
    }
  end

  def opened
    common_zip.select {|(o, n)|
      o['state'] == 'closed' and o['state'] != n['state']
    }.map(&:last)
  end

  def closed
    common_zip.select {|(o, n)|
      o['state'] == 'open' and o['state'] != n['state']
    }.map(&:last)
  end

protected
  def common_zip
    numbers = old.map {|x| x['number'] } & new.map {|x| x['number'] }
    old.sort_by {|x| x['number'] }.select {|x| numbers.include?(x['number']) }.zip(
      new.sort_by {|x| x['number'] }.select {|x| numbers.include?(x['number']) })
  end

  def comments(id)
    uri = URI.parse("http://github.com/api/v2/yaml/issues/comments/#@user/#@repo/#{id}")
    YAML.load(Net::HTTP.get(uri))['comments']
  end
end

class UserDiff
  attr_reader :repos

  def initialize (user, cache=File.join(ENV['HOME'], '.issuecache.yml'))
    @user = user
    @cachefile = cache
    begin
      cache = File.exists?(cache) ? YAML.load(File.read(cache)) : {repos: {}, ignore: {}}
    rescue ArgumentError
      File.unlink(cache)
      cache = {repos: {}, ignore: {}}
    end

    @repos = Hash[cache[:repos].map {|k, v|
      [k, IssueDiff.new(user, k, v, cache[:ignore][k])]
    }]
  end

  def ignore (repo, id)
    self[repo].tap {|repo|
      break repo ? repo.ignore(id) : false
    }.tap {
      self.save
    }
  end

  def unignore (repo, id)
    self[repo].tap {|repo|
      break repo ? repo.unignore(id) : false
    }.tap {
      self.save
    }
  end

  def ignoring
    Hash[repos.map {|k, v|
      [k, v.ignoring]
    }]
  end

  def refresh
    self.get_repos.each {|repo|
      @repos[repo] = IssueDiff.new(@user, repo) unless @repos.keys.include?(repo)
    }

    @repos.each {|n, diff|
      diff.refresh
    }

    self.save
    self
  end

  def each (&blk)
    @repos.each(&blk)
  end

  def [] (repo)
    @repos[repo]
  end

protected
  def get_repos
    uri = URI.parse("http://github.com/api/v2/yaml/repos/show/#@user")
    YAML.load(Net::HTTP.get(uri))['repositories'].map {|x|
      x['name'] || x[:name]
    }
  end

  def save
    File.open(@cachefile, 'w+') {|f|
      f.write({
        ignore: self.ignoring,
        repos: Hash[repos.map {|k,v| [k, v.issues] }]
      }.to_yaml)
    }
  end
end

class LogSocket < TCPSocket
  def initialize (host, port, stdout=true, file=File.join(ENV['HOME'], '.issuebot.log'))
    @logger = false
    @logger = File.open(file, 'w+') rescue false if file
    @stdout = stdout
    super(host, port)
  end

  def write (what)
    @logger.write('<< ' + what) if @logger
    $stdout.write('<< ' + what) if @stdout
    super(what)
  end

  def gets
    super.tap {|msg|
      @logger.write('>> ' + msg) if @logger
      $stdout.write('>> ' + msg) if @stdout
    }
  end

  def close
    @logger.close if @logger
    super
  end
end

class SSLogSocket < OpenSSL::SSL::SSLSocket
  def initialize (host, port, stdout=true, file=File.join(ENV['HOME'], '.issuebot.log'))
    @logger = false
    @logger = File.open(file, 'w+') rescue false if file
    @stdout = stdout
    super(TCPSocket.new(host, port))
    self.connect
  end

  def write (what)
    @logger.write('<< ' + what) if @logger
    $stdout.write('<< ' + what) if @stdout
    super(what)
  end

  def gets
    super.tap {|msg|
      @logger.write('>> ' + msg) if @logger
      $stdout.write('>> ' + msg) if @stdout
    }
  end

  def close
    @logger.close if @logger
    super
  end

  class << self; alias open new; end
end

class Bit
  def self.ly (url)
    uri = URI.parse("http://api.bit.ly/v3/shorten?longUrl=#{CGI.escape(url)}&format=json"+
    "&apiKey=R_93135b9bc0f5d029f477012858a80057&login=issuebot")
    res = JSON.parse(Net::HTTP.get(uri))
    return url if res['status_code'].to_i != 200
    res['data']['url'] || url
  rescue
    url
  end
end

def bit; Bit; end

def sprunge(what)
  Net::HTTP.post_form(URI.parse('http://sprunge.us/'), {
    'sprunge' => what
  }).body.strip
rescue
  nil
end

def log_error
  yield if block_given?
rescue Exception => e
  $sock.write("PRIVMSG #{CHAN} :#{e.backtrace.first}: #{e.to_s.gsub(/\n/, '\n')} - %s\r\n" % [
    sprunge((["#{caller[0]}: #{e}"] + e.backtrace.map {|x| '  ' + x }).join("\n"))
  ])
end

$last_check = Time.now - CHECK_TIME
$diff = UserDiff.new(USER)

def check_update
  $diff.refresh

  $diff.each {|repo, diff|
    diff.created.each {|new|
      $sock.write("PRIVMSG #{CHAN} :\x033%s\x03 > \x036%s\x03 \x02\x035created\x03\x02[\x02%d\x02] | %s - %s\r\n" % [new['user'], repo, new['number'], new['title'], bit.ly(new['html_url'])])
    }

    diff.removed.each {|del|
      $sock.write("PRIVMSG #{CHAN} :\x033%s\x03 > \x036%s\x03 \x02\x035deleted\x03\x02[\x02%d\x02] | %s\r\n" % [del['user'], repo, del['number'], del['title']])
    }

    diff.opened.each {|open|
      $sock.write("PRIVMSG #{CHAN} :\x033%s\x03 > \x036%s\x03 \x02\x035opened\x03\x02[\x02%d\x02] | %s - %s\r\n" % [open['user'], repo, open['number'], open['title'], bit.ly(open['html_url'])])
    }

    diff.closed.each {|closed|
      $sock.write("PRIVMSG #{CHAN} :\x033%s\x03 > \x036%s\x03 \x02\x035closed\x03\x02[\x02%d\x02] | %s - %s\r\n" % [closed['user'], repo, closed['number'], closed['title'], bit.ly(closed['html_url'])])
    }

    diff.commented.each {|issue|
      issue['comments'].each {|comment|
        $sock.write("PRIVMSG #{CHAN} :\x033%s\x03 > \x036%s\x03 \x02\x035commented\x03\x02[\x02%d\x02] | %s - %s\r\n" % [comment['user'], repo, issue['number'], issue['title'], bit.ly(issue['html_url'])])
      }
    }
  }
end

COMMANDS = {
  /^PI(NG.+)$/ => lambda {|match| $sock.write("PO#{match[1]}\r\n") },
  /^:\S+\s+001/ => lambda { $sock.write("JOIN :#{CHAN}\r\n") },
  /^:\S+\s+NOTICE\s+\S+\s+:\*\*\*\s+.*?hostname/i => lambda {
    $sock.write("USER #{NAME} 0 * :#{NAME}\r\n")
    $sock.write("NICK #{NAME}\r\n")
  },
  /^:\S+\s+PRIVMSG\s+#{Regexp.escape(CHAN)}\s+:!check\s*$/ => lambda {
    check_update
  },
  /^:#{Regexp.escape(NAME)}!\S+\s+JOIN\s+:#{Regexp.escape(CHAN)}/ => lambda {
    $sock.write("PRIVMSG #{CHAN} :HO HAI! ^_^\r\n")
    $joined = true
  },
  /^:\S+\s+PRIVMSG\s+#{Regexp.escape(CHAN)}\s+:~ignore\s+(.+?)\s+(\d+)\s*$/ => lambda {|match|
    $sock.write("PRIVMSG #{CHAN} :ignoring #{match[1]} ##{match[2]}\r\n")
    $diff.ignore(match[1], match[2])
  },
  /^:\S+\s+PRIVMSG\s+#{Regexp.escape(CHAN)}\s+:~unignore\s+(.+?)\s+(\d+)\s*$/ => lambda {|match|
    $sock.write("PRIVMSG #{CHAN} :unignoring #{match[1]} ##{match[2]}\r\n")
    $diff.unignore(match[1], match[2])
  }
}

[:INT, :KILL, :HUP].each {|sig|
  trap(sig) {
    $sock.write("QUIT :no more issuebot :(\r\n")
    $sock.close
    exit 1
  }
}

$joined = false
$sock = (SSL ? SSLogSocket : LogSocket).open(SERVER, PORT, LOGSTDOUT, LOGFILE)
$stdout.puts "Connected :D"

COMMANDS.dup.each {|reg, blk|
  COMMANDS.delete(reg) if blk.arity > 1
}

loop do
  res = IO.select([$sock, STDIN], nil, nil, 2)

  if $joined and $last_check < (Time.now - CHECK_TIME)
    $last_check = Time.now
    log_error {
      check_update
    }
  end

  if res
    res.first.each {|io|
      if io == STDIN
        $sock.write(io.gets.gsub(/\r?\n/, "\r\n"))
      else
        msg = log_error {
          $sock.gets
        }

        COMMANDS.each {|reg, blk|
          matches = reg.match(msg)
          if matches
            log_error {
              if blk.arity == 0
                blk.call
              elsif blk.arity <= 1
                blk.call(matches)
              end
            }
          end
        }
      end
    }
  end
end
