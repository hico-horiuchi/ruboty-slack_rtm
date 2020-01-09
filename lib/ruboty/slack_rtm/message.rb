require 'ruboty/message'

module Ruboty
  module SlackRTM
    module Message
      def reply(body, options = {})
        attributes = { body: body, from: to, to: from, original: original, thread_ts: thread_ts }.merge(options)
        robot.say(attributes)
      end

      def add_reaction(reaction)
        channel_id = @original[:from]
        timestamp  = sprintf("%.6f", @original[:time].to_f)
        robot.add_reaction(reaction, channel_id, timestamp)
      end

      def thread_ts
        @original[:thread_ts]
      end
    end
  end

  Message.prepend SlackRTM::Message
end
