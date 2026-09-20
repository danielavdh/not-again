class Shrine
  module Plugins
    # Shrine.plugin :pc_partition
    # "users/avatars/000/000/564/thumb/493g82jf23.jpg"
    module PcPartition
      module InstanceMethods
        def generate_location(io, context)
          if context[:record]
            type = class_location(context[:record].class).pluralize if context[:record].class.name
            if context[:record].respond_to?(:id)
              id = id_partition(context[:record].id)
            end
            derivative = context[:derivative] || :original
          end
          name = context[:name].to_s.pluralize.to_sym
          original_name = extract_filename(io)

          # Defence in depth, not the real access control — Receipt#download
          # already authorises with a signed id before it ever reaches this
          # path.
          #
          # This exists for the day the BUCKET itself is misconfigured public.
          # Without it every key is type/name/000/000/id/derivative/filename —
          # sequential and guessable from nothing but a receipt's own database
          # id. With it, listing the bucket still tells you nothing about
          # individual files: you would have to already know the random segment.
          #
          # Its own path component, placed BEFORE the filename, on purpose:
          # every uploader that overrides generate_location only replaces the
          # LAST segment, so inserting anything before it needs no changes
          # there.
          random = SecureRandom.hex(8)

          [type, name, id, derivative, random, original_name].compact.join("/")
        end

        private

        def class_location(klass)
          klass.name.downcase.split("::").join('_')
        end
        def extract_filename(io)
          if io.respond_to?(:original_filename)
            io.original_filename
          elsif io.respond_to?(:path)
            File.basename(io.path)
          end
        end
        def id_partition(id)
          case id
            when Integer
              ("%09d".freeze % id).scan(/\d{3}/).join("/".freeze)
            when String
              id.scan(/.{3}/).first(3).join("/".freeze)
            else
              nil
          end
        end
      end
    end
    register_plugin(:pc_partition, PcPartition)
  end
end
    
  