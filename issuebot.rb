#!/homex/rizzle/.multiruby/install/1.9.1-p431/bin/ruby

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
  attr_reader :old
  def initialize(*args)
    @fetcher = IssueFetcher.new(*args)
    @old = @fetcher.issues
  end

  def new
    @new ||= @fetcher.fetch
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
    }.map(&:last)
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
    (old - removed).zip(new - created)
  end
end

class UserDiff
  attr_reader :repos

  def initialize (user, cache=File.join(ENV['HOME'], '.issuecache.yml'))
    @user = user
    @cachefile = cache
    begin
      @cache = File.exists?(cache) ? YAML.load(File.read(cache)) : {}
    rescue ArgumentError
      File.unlink(cache)
      @cache = {}
    end

    @repos = Hash[@cache.map {|k, v|
      [k, IssueDiff.new(user, k, v)]
    }]
  end

  def refresh
    self.get_repos.each {|repo|
      @repos[repo] = IssueDiff.new(@user, repo) unless @repos.keys.include?(repo)
    }

    @repos.each {|n, diff|
      diff.refresh
    }

    File.open(@cachefile, 'w+') {|f|
      f.write(Hash[repos.map {|k,v| [k, v.issues] }].to_yaml)
    }
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
end

class LogSocket < TCPSocket
  def initialize (host, port, stdout=true, file=File.join(ENV['HOME'], '.issuebot.log'))
    @logger = false
    @logger = File.open(file, 'w+') if file and File.exists?(file)
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
    @logger = File.open(file, 'w+') if file and File.exists?(file)
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

SERVER = 'irc.freenode.net'
PORT = 6697
SSL = true
CHAN = '##distro'
NAME = 'issuebot'

USER = 'distro'
CHECK_TIME = 60

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
      $sock.write("PRIVMSG #{CHAN} :\x033%s\x03 > \x036%s\x03 \x02\x035commented\x03\x02[\x02%d\x02] | %s - %s\r\n" % [issue['user'], repo, issue['number'], issue['title'], bit.ly(issue['html_url'])])
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
  }
}

[:INT, :KILL, :HUP].each {|sig|
  trap(sig) {
    $sock.write("QUIT :no more issuebot :(\r\n")
    $sock.close
    exit 1
  }
}

$sock = (SSL ? SSLogSocket : LogSocket).open(SERVER, PORT)
$stdout.puts "Connected :D"

loop do
  res = IO.select([$sock, STDIN], nil, nil, 2)

  if Time.now <= $last_check + CHECK_TIME
    $last_check = Time.now
    check_update
  end

  if res
    res.first.each {|io|
      if io == STDIN
        $sock.write(io.gets.gsub(/\r?\n/, "\r\n"))
      else
        msg = $sock.gets
        COMMANDS.each {|reg, blk|
          matches = reg.match(msg)
          if matches
            begin
              begin
                blk.call(matches)
              rescue ArgumentError
                blk.call
              end
            rescue Exception => e
              $sock.write("PRIVMSG #{CHAN} :#{e.backtrace.first}: #{e.to_s.gsub(/\n/, '\n')} - %s\r\n" % [
                          sprunge((["#{caller[0]}: #{e}"] + e.backtrace.map {|x| '  ' + x }).join("\n"))
              ])
            end
          end
        }
      end
    }
  end
end