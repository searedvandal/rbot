# encoding: UTF-8
#-- vim:sw=2:et
#++
#
# :title: journal backend for postgresql

require 'pg'
require 'json'

module Irc
class Bot
module Journal

  class Query
  end

  module Storage

    class PostgresStorage < AbstractStorage
      attr_reader :conn

      def initialize(opts={})
        @uri = opts[:uri] || 'postgresql://localhost/rbot_journal'
        @conn = PG.connect(@uri)
        @version = @conn.exec('SHOW server_version;')[0]['server_version']

        @version.gsub!(/^(\d+\.\d+)$/, '\1.0')
        log 'journal storage: postgresql connected to version: ' + @version
        
        version = @version.split('.')[0,3].join.to_i
        if version < 930
          raise StorageError.new(
            'PostgreSQL Version too old: %s, supported: >= 9.3' % [@version])
        end
        @jsonb = (version >= 940)
        log 'journal storage: no jsonb support, consider upgrading postgres' unless @jsonb

        drop if opts[:drop]
        create_table
      end

      def create_table
        @conn.exec('
          CREATE TABLE IF NOT EXISTS journal
            (id UUID PRIMARY KEY,
             topic TEXT NOT NULL,
             timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
             payload %s NOT NULL)' % [@jsonb ? 'JSONB' : 'JSON'])
      end

      def insert(m)
        @conn.exec_params('INSERT INTO journal VALUES ($1, $2, $3, $4);',
          [m.id, m.topic, m.timestamp, JSON.generate(m.payload)])
      end

      def find(query, limit=100, offset=0)
        sql, params = query_to_sql(query)
        sql = 'SELECT * FROM journal WHERE ' + sql + ' LIMIT %d OFFSET %d' % [limit.to_i, offset.to_i]
        res = @conn.exec_params(sql, params)
        res.map do |row|
          timestamp = DateTime.strptime(row['timestamp'], '%Y-%m-%d %H:%M:%S%z')
          JournalMessage.new(id: row['id'], timestamp: timestamp,
            topic: row['topic'], payload: JSON.parse(row['payload']))
        end
      end

      # returns the number of messages that match the query
      def count(query)
        sql, params = query_to_sql(query)
        sql = 'SELECT COUNT(*) FROM journal WHERE ' + sql
        res = @conn.exec_params(sql, params)
        res[0]['count'].to_i
      end

      def drop
        @conn.exec('DROP TABLE journal;') rescue nil
      end

      def query_to_sql(query)
        params = []
        placeholder = Proc.new do |value|
          params << value
          '$%d' % [params.length]
        end
        sql = {op: 'AND', list: []}

        # ID query OR condition
        unless query.id.empty?
          sql[:list] << {
            op: 'OR',
            list: query.id.map { |id| 
              'id = ' + placeholder.call(id)
            }
          }
        end

        # Topic query OR condition
        unless query.topic.empty?
          sql[:list] << {
            op: 'OR',
            list: query.topic.map { |topic| 
              'topic ILIKE ' + placeholder.call(topic.gsub('*', '%'))
            }
          }
        end

        # Timestamp range query AND condition
        if query.timestamp[:from] or query.timestamp[:to]
          list = []
          if query.timestamp[:from]
            list << 'timestamp >= ' + placeholder.call(query.timestamp[:from])
          end
          if query.timestamp[:to]
            list << 'timestamp <= ' + placeholder.call(query.timestamp[:to])
          end
          sql[:list] << {
            op: 'AND',
            list: list
          }
        end

        # Payload query
        unless query.payload.empty?
          list = []
          query.payload.each_pair do |key, value|
            selector = 'payload'
            k = key.to_s.split('.')
            k.each_index { |i|
              if i >= k.length-1
                selector += '->>\'%s\'' % [@conn.escape_string(k[i])]
              else
                selector += '->\'%s\'' % [@conn.escape_string(k[i])]
              end
            }
            list << selector + ' = ' + placeholder.call(value)
          end
          sql[:list] << {
            op: 'OR',
            list: list
          }
        end

        sql = sql[:list].map { |stmt|
          '(' + stmt[:list].join(' %s ' % [stmt[:op]]) + ')'
        }.join(' %s ' % [sql[:op]])

        [sql, params]
      end
    end
  end
end # Journal
end # Bot
end # Irc