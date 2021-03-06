require 'cgi'
require 'open-uri'
require 'active_support/all'
require 'net/http'

DROPLET_SIZE = 'g-4vcpu-16gb'

class Say
  class << self
    def rcon(command)
      rcon = RCON::Minecraft.new ENV['RCON_IP'], ENV['RCON_PORT'] || 25575
      rcon.auth ENV['RCON_PASSWORD']
      rcon.command(command).strip
    end

    def game(user_name, text)
      # Replace curly single and double quotes with non-Unicode versions
      text.gsub!(/[\u201c\u201d]/, '"')
      text.gsub!(/[\u2018\u2019]/, "'")

      data = { text: "<#{user_name.gsub(/\Aslackbot\z/, 'Steve')}> #{CGI.unescapeHTML(text.gsub(/<(\S+)>/, "\\1"))}" }
      rcon %|tellraw @a ["",#{data.to_json}]|
    end

    def slack(user_name, text)
      RestClient.post ENV['SLACK_URL'], {
#        username: user_name, text: text.gsub(/\[m\Z/, ""), icon_url: "https://minotar.net/avatar/#{user_name}?date=#{Date.today}"
        username: user_name, text: text.gsub(/\[m\Z/, ""), icon_url: "https://minotar.net/helm/#{user_name}?date=#{Date.today}"
      }.to_json, content_type: :json, accept: :json
    end
  end
end

class Command
  def initialize(who, line)
    @who = who
    @line = line
  end

  def run
    execute if allowed?
  end

  private
    def execute
      raise NotImplementedError
    end

    def allowed?
      %w( qrush tyrosinase bensawyer fishtoaster cobyr ravenx99
        uncleadam sleeplessbooks ).include? @who
    end

    def slack(line)
      Say.slack 'MC_wither', line
    end

    def set_config_var(key, value)
      heroku = PlatformAPI.connect_oauth(ENV['HEROKU_PLATFORM_API_TOKEN'])
      heroku.config_var.update('wither', {key => value})
    end
end

class DnsCommand < Command
  FILENAME = 'Kpickaxe.+157+50170'
  def execute
    puts "executing DNS command: #{@line}"
    if @line =~ /^wither dns ([\w-]+) ([\d\.]+)$/
      ensure_keys
      if system("sh ./change_dns.sh #{$1}.pickaxe.club #{$2}")
        puts "---=== moving pickaxe to #{$1} at #{$2}"
        slack "I've moved pickaxe to #{$1}.pickaxe.club, pointing at #{$2}. :pickaxe:"
        sleep 2
        puts "---=== having slept, setting RCON_IP to #{$2}"
        set_config_var('RCON_IP', $2)
        puts "---=== [[unreachable code, since set_config_var reboots?]]"
      else
        slack "Dns update failed."
      end
    end
  end

  private

  # Make sure the keys necessary for the dns update are on the filesystem
  def ensure_keys
    return if File.exist?(private_file) && File.exist?(key_file)

    File.open(private_file, 'w') { |f| f.write(ENV['DNS_PRIVATE']) }
    File.open(key_file, 'w') { |f| f.write(ENV['DNS_KEY']) }
  end

  def private_file
    './' + FILENAME + '.private'
  end

  def key_file
    './' + FILENAME + '.key'
  end
end

class SayCommand < Command
  def execute
    Say.game @who, @line
  end

  def allowed?
    true
  end
end

class ListCommand < Command
  def execute
    list = Say.rcon('list')
    slack list
    Say.game 'MC_wither', list
  end

  def allowed?
    true
  end
end

class DropletCommand < Command
  private
    def client
      @client ||= DropletKit::Client.new(access_token: ENV['DO_ACCESS_TOKEN'])
    end

    def droplet
      @droplet ||= client.droplets.all.find { |drop| drop.name == 'pickaxe.club' }
    end
end

class StatusCommand < DropletCommand
  def execute
    if droplet
      public_ip = droplet.public_ip

      Net::SSH.start(public_ip, "minecraft", :password => ENV['DO_SSH_PASSWORD'], :timeout => 10) do |ssh|
        output = ssh.exec!("uptime")
        slack "Pickaxe.club is online at #{public_ip}. `#{output.strip}`"
      end
    else
      slack "Pickaxe.club is offline!"
    end
  rescue Errno::ETIMEDOUT
    slack "Pickaxe.club is timing out. Maybe offline?"
  end

  def allowed?
    true
  end
end

class BootCommand < DropletCommand
  def execute
    if droplet
      Say.slack 'MC_wither', 'Pickaxe.club is already running!'
      return
    end

    unless @line =~ /^[Ww]ither boot (\d{3}[a-z]?)$/
      slack "syntax: wither boot <restore_week_number>"
      return
    end
    restore_week = $1

    unless restore_file_exists(restore_week)
      slack "restore file for week #{restore_week} not found. Check logs."
      return
    end

    set_config_var 'BOOT_RESTORE_WEEK', restore_week

    droplet = DropletKit::Droplet.new(
      name: 'pickaxe.club',
      region: 'nyc3',
      image: 'ubuntu-16-04-x64',
      size: DROPLET_SIZE,
      private_networking: true,
      user_data: open(ENV['DO_USER_DATA_URL']).read # ROFLMAO
    )
    client.droplets.create(droplet)
    slack "Pickaxe.club is booting up! (restoring week #{restore_week})"
  end

  def restore_file_exists(week)
    url = URI(ENV['ARCHIVE_URL'] + "/week#{week}.tar.gz")
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true
    response = http.head(url.path)
    puts "HEAD request response: #{response} #{url}"
    response.code == "200"
  end
end

class ShutdownCommand < DropletCommand
  def execute
    if droplet
      client.droplets.delete(id: droplet.id)

      slack "Pickaxe.club is shutting down. I hope it was backed up!"
    else
      slack "Pickaxe.club isn't running."
    end
  end
end

class BossCommand < Command
  def execute
    puts "input to boss command:"
    puts @line
    slack "you are the boss"
    Say.game 'MC_wither', "you are the big boss"
  end
end


class Wither < Sinatra::Application
  COMMANDS = %w(list dns ip boot shutdown status backup generate boss)

  get '/' do
    'Wither!'
  end

  get '/restore-week' do
    ENV['BOOT_RESTORE_WEEK']
  end

  post '/hook' do
    text = params[:text]
    user_name = params[:user_name]

    if text == nil || text == '' || user_name == 'slackbot'
      return 'nope'
    end

    if params[:token] == ENV['SLACK_TOKEN']
      wither, command, * = text.split

      if wither.downcase == "wither" && COMMANDS.include?(command)
        puts "recognized wither command: #{command} text: #{text}"
        command_class = "#{command}_command".camelize.safe_constantize
        command_class.new(user_name, text).run
      else
        begin
          SayCommand.new(user_name, text).run
        rescue Exception => e
          logger.info "Got error #{e.class}"
          logger.info "Port = #{ENV['RCON_PORT'] || 25575}"
          logger.info "IP = #{ENV['RCON_IP']}"
          logger.info "password = #{ENV['RCON_PASSWORD']}"
          raise e
        end
      end

      status 201
    else
      status 403
    end

    'ok'
  end

  post '/minecraft/hook' do
    body = request.body.read
    logger.info body

    if body =~ /INFO\]: <(.*)> (.*)/
      Say.slack $1, $2
    elsif body =~ %r{Server thread/INFO\]: ([^\d]+)}
      line = $1
      Say.slack 'MC_wither', line if line !~ /the game/
    end

    'ok'
  end

  post '/cloud/booted/:instance_id' do
    logger.info params.inspect
    instance_id = params[:instance_id]
    Say.slack "wither", "I've finished booting #{instance_id}!"
  end
end
