require 'cgi'
require 'etc'
require 'time'
require 'json'
require 'slack'
require 'ruboty/adapters/base'
require 'faraday'

module Ruboty
  module Adapters
    class SlackRTM < Base
      env :SLACK_TOKEN, "Account's token. get one on https://api.slack.com/web#basics"
      env :SLACK_EXPOSE_CHANNEL_NAME, "if this set to 1, message.to will be channel name instead of id", optional: true
      env :SLACK_IGNORE_BOT_MESSAGE, "If this set to 1, bot ignores bot_messages", optional: true
      env :SLACK_IGNORE_GENERAL, "if this set to 1, bot ignores all messages on #general channel", optional: true
      env :SLACK_GENERAL_NAME, "Set general channel name if your Slack changes general name", optional: true
      env :SLACK_AUTO_RECONNECT, "Enable auto reconnect", optional: true

      def run
        init
        bind
        connect
      end

      def say(message)
        channel = message[:to]
        if channel[0] == '#'
          channel = resolve_channel_id(channel[1..-1])
        end

        return unless channel

        args = {
          as_user: true
        }
        if message[:thread_ts] || (message[:original] && message[:original][:thread_ts])
          args.merge!(thread_ts: message[:thread_ts] || message[:original][:thread_ts])
        end

        if message[:attachments] && !message[:attachments].empty?
          args.merge!(
            channel: channel,
            text: message[:code] ? "```\n#{message[:body]}\n```" : message[:body],
            parse: message[:parse] || 'full',
            unfurl_links: true,
            attachments: message[:attachments].to_json
          )
          client.chat_postMessage(args)
        elsif message[:file]
          path = message[:file][:path]
          args.merge!(
            channels: channel,
            file: Faraday::UploadIO.new(path, message[:file][:content_type]),
            title: message[:file][:title] || path,
            filename: File.basename(path),
            initial_comment: message[:body] || ''
          )
          client.files_upload(args)
        else
          args.merge!(
            channel: channel,
            text: message[:code] ? "```\n#{message[:body]}\n```" : resolve_send_mention(message[:body]),
            mrkdwn: true
          )
          client.chat_postMessage(args)
        end
      end

      def add_reaction(reaction, channel_id, timestamp)
        client.reactions_add(name: reaction, channel: channel_id, timestamp: timestamp)
      end

      private

      def init
        response = client.auth_test
        @user_info_caches = {}
        @channel_info_caches = {}
        @usergroup_info_caches = {}

        ENV['RUBOTY_NAME'] ||= response['user']

        make_users_cache
        make_channels_cache
        make_usergroups_cache
      end

      def bind
        realtime.on_text do |data|
          method_name = "on_#{data['type']}".to_sym
          send(method_name, data) if respond_to?(method_name, true)
        end
      end

      def connect
        Thread.start do
          loop do
            sleep 5
            set_active
          end
        end

        loop do
          realtime.main_loop rescue nil
          break unless ENV['SLACK_AUTO_RECONNECT']
          @url = nil
          @realtime = nil
          sleep 3
          bind
        end
      end

      def url
        @url ||= begin
          response = Net::HTTP.post_form(URI.parse('https://slack.com/api/rtm.connect'), token: ENV['SLACK_TOKEN'])
          body = JSON.parse(response.body)

          URI.parse(body['url'])
        end
      end

      def client
        @client ||= if Etc.uname[:sysname] == 'Linux'
                      ::Slack::Client.new(
                        token: ENV['SLACK_TOKEN'],
                        ca_path: '/etc/ssl/certs',
                        ca_file: '/etc/ssl/certs/ca-certificates.crt'
                      )
                    elsif Etc.uname[:sysname] == 'Darwin'
                      ::Slack::Client.new(
                        token: ENV['SLACK_TOKEN'],
                        ca_path: '/private/etc/ssl',
                        ca_file: '/private/etc/ssl/cert.pem'
                      )
                    else
                      ::Slack::Client.new(token: ENV['SLACK_TOKEN'])
                    end
      end

      def realtime
        @realtime ||= ::Ruboty::SlackRTM::Client.new(websocket_url: url)
      end

      def expose_channel_name?
        if @expose_channel_name.nil?
          @expose_channel_name = ENV['SLACK_EXPOSE_CHANNEL_NAME'] == '1'
        else
          @expose_channel_name
        end
      end

      def set_active
        client.users_setActive
      end

      # event handlers

      def on_message(data)
        user = user_info(data['user']) || {}

        channel = channel_info(data['channel'])

        if (data['subtype'] == 'bot_message' || user['is_bot']) && ENV['SLACK_IGNORE_BOT_MESSAGE'] == '1'
          return
        end

        if channel
          return if channel['name'] == (ENV['SLACK_GENERAL_NAME'] || 'general') && ENV['SLACK_IGNORE_GENERAL'] == '1'

          channel_to = expose_channel_name? ? "##{channel['name']}" : channel['id']
        else # direct message
          channel_to = data['channel']
        end

        message_info = {
          from: data['channel'],
          from_name: user['name'],
          to: channel_to,
          channel: channel,
          user: user,
          ts: data['ts'],
          thread_ts: data['thread_ts'],
          time: Time.at(data['ts'].to_f)
        }

        text, mention_to = extract_mention(data['text'])
        robot.receive(message_info.merge(body: text, mention_to: mention_to))

        (data['attachments'] || []).each do |attachment|
          body, body_mention_to = extract_mention(attachment['fallback'] || "#{attachment['text']} #{attachment['pretext']}".strip)

          unless body.empty?
            robot.receive(message_info.merge(body: body, mention_to: body_mention_to))
          end
        end
      end

      def on_channel_change(data)
        make_channels_cache
      end
      alias_method :on_channel_deleted, :on_channel_change
      alias_method :on_channel_renamed, :on_channel_change
      alias_method :on_channel_archived, :on_channel_change
      alias_method :on_channel_unarchived, :on_channel_change

      def on_user_change(data)
        user = data['user'] || data['bot']
        @user_info_caches[user['id']] = user
      end
      alias_method :on_bot_added, :on_user_change
      alias_method :on_bot_changed, :on_user_change

      def extract_mention(text)
        mention_to = []

        text = (text || '').gsub(/\<\@(?<uid>[0-9A-Z]+)(?:\|(?<name>[^>]+))?\>/) do |_|
          name = Regexp.last_match[:name]

          unless name
            user = user_info(Regexp.last_match[:uid])

            mention_to << user

            name = user['name']
          end

          "@#{name}"
        end

        text.gsub!(/\<!subteam\^(?<usergroup_id>[0-9A-Z]+)(?:\|(?<handle>[^>]+))?\>/) do |_|
          handle = Regexp.last_match[:handle]

          unless handle
            handle = usergroup_info(Regexp.last_match[:usergroup_id])
          end

          "#{handle}"
        end

        text.gsub!(/\<!(?<special>[^>|@]+)(\|\@[^>]+)?\>/) do |_|
          "@#{Regexp.last_match[:special]}"
        end

        text.gsub!(/\<((?<link>[^>|]+)(?:\|(?<ref>[^>]*))?)\>/) do |_|
          Regexp.last_match[:ref] || Regexp.last_match[:link]
        end


        text.gsub!(/\#(?<room_id>[A-Z0-9]+)/) do |_|
          room_id = Regexp.last_match[:room_id]
          msg = "##{room_id}"

          if channel = channel_info(room_id)
            msg = "##{channel['name']}"
          end

          msg
        end

        [CGI.unescapeHTML(text), mention_to]
      end

      def resolve_send_mention(text)
        return '' if text.nil?
        text = text.dup.to_s
        text.gsub!(/@(?<mention>[0-9a-z._-]+)/) do |_|
          mention = Regexp.last_match[:mention]
          msg = "@#{mention}"

          @user_info_caches.each_pair do |id, user|
            mention_names = [user['name'].downcase]
            mention_names.push(user['profile']['display_name'].downcase) if user['profile'].present?

            if mention_names.include?(mention.downcase)
              msg = "<@#{id}>"
            end
          end

          msg
        end

        text.gsub!(/@(?<special>(?:everyone|group|channel|here))/) do |_|
          "<!#{Regexp.last_match[:special]}>"
        end

        text.gsub!(/@(?<subteam_name>[0-9a-z._-]+)/) do |_|
          subteam_name = Regexp.last_match[:subteam_name]
          msg = "@#{subteam_name}"

          @usergroup_info_caches.each_pair do |id, usergroup|
            if usergroup && usergroup['handle'] == subteam_name
              msg = "<!subteam^#{usergroup['id']}>"
            end
          end
          msg
        end

        text.gsub!(/\#(?<room_id>[a-z0-9_-]+)/) do |_|
          room_id = Regexp.last_match[:room_id]
          msg = "##{room_id}"

          @channel_info_caches.each_pair do |id, channel|
            if channel && channel['name'] == room_id
              msg = "<##{id}|#{room_id}>"
            end
          end

          msg
        end

        text
      end

      def make_users_cache
        users = []
        options = { limit: 1_000 }
        resp = client.users_list(options)

        if resp['ok']
          users.concat(resp['members'])

          while resp&.[]('response_metadata')&.[]('next_cursor') != ''
            options[:cursor] = resp['response_metadata']['next_cursor']
            resp = client.users_list(options)
            users.concat(resp['members']) if resp['ok']
          end
        end

        users.each do |user|
          @user_info_caches[user['id']] = user
        end
      end

      def make_channels_cache
        channels = []
        options = { limit: 1_000, exclude_archived: true }
        resp = client.conversations_list(options)

        if resp['ok']
          channels.concat(resp['channels'])

          while resp&.[]('response_metadata')&.[]('next_cursor') != ''
            options[:cursor] = resp['response_metadata']['next_cursor']
            resp = client.conversations_list(options)
            channels.concat(resp['channels']) if resp['ok']
          end
        end

        channels.each do |channel|
          @channel_info_caches[channel['id']] = channel
        end
      end

      def make_usergroups_cache
        usergroups = []
        options = { limit: 1_000, include_count: false, include_disabled: false, include_users: false }
        resp = client.get("usergroups.list", options)

        if resp['ok']
          usergroups.concat(resp['usergroups'])

          while resp&.[]('response_metadata')&.[]('next_cursor') != ''
            options[:cursor] = resp['response_metadata']['next_cursor']
            resp = client.get("usergroups.list", options)
            usergroups.concat(resp['usergroups']) if resp['ok']
          end
        end

        usergroups.each do |usergroup|
          @usergroup_info_caches[usergroup['id']] = usergroup
        end
      end

      def user_info(user_id)
        return {} if user_id.to_s.empty?

        @user_info_caches[user_id] ||= begin
          resp = client.users_info(user: user_id)

          resp['user']
        end
      end

      def channel_info(channel_id)
        @channel_info_caches[channel_id] ||= begin
          resp = case channel_id
            when /^C/
              client.conversations_info(channel: channel_id)
            else
              {}
            end

          resp['channel']
        end
      end

      def resolve_channel_id(name)
        ret_id = nil
        @channel_info_caches.each_pair do |id, channel|
          if channel['name'] == name
            ret_id = id
            break
          end
        end
        return ret_id
      end

      def usergroup_info(usergroup_id)
        @usergroup_info_caches[usergroup_id] || begin
          make_usergroups_cache
          @usergroup_info_caches[usergroup_id]
        end
      end
    end
  end
end
