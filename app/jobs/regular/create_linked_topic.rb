# frozen_string_literal: true

module Jobs
  class CreateLinkedTopic < ::Jobs::Base

    def execute(args)
      reference_post = Post.find_by(id: args[:post_id])
      return unless reference_post.present?
      parent_topic = reference_post.topic
      return unless parent_topic.present?
      parent_topic_id = parent_topic.id
      parent_title = parent_topic.title

      ActiveRecord::Base.transaction do
        linked_topic_record = parent_topic.linked_topic
        if linked_topic_record.present?
          raw_title = parent_title.delete_suffix(I18n.t("create_linked_topic.topic_title_with_sequence", topic_title: "", count: linked_topic_record.sequence))
          original_topic_id = linked_topic_record.original_topic_id
          sequence = linked_topic_record.sequence + 1
        else
          raw_title = parent_title

          # update parent topic title to append title_suffix_locale
          parent_title = I18n.t("create_linked_topic.topic_title_with_sequence", topic_title: parent_title, count: 1)
          parent_topic.title = parent_title
          parent_topic.save!

          # create linked topic record
          original_topic_id = parent_topic_id
          LinkedTopic.create!(topic_id: parent_topic_id, original_topic_id: original_topic_id, sequence: 1)
          sequence = 2
        end

        # fetch previous topic titles
        previous_topics = ""
        linked_topic_ids = LinkedTopic.where(original_topic_id: original_topic_id).pluck(:topic_id)
        Topic.where(id: linked_topic_ids).order(:id).each do |topic|
          previous_topics += "- [#{topic.title}](#{topic.url})\n"
        end

        # create new topic
        new_topic_title = I18n.t("create_linked_topic.topic_title_with_sequence", topic_title: raw_title, count: sequence)
        new_topic_raw = I18n.t('create_linked_topic.post_raw', parent_title: "[#{parent_title}](#{reference_post.full_url})", previous_topics: previous_topics)
        system_user = Discourse.system_user
        new_post = PostCreator.create!(
          system_user,
          title: new_topic_title,
          raw: new_topic_raw,
          skip_validations: true)
        new_topic = new_post.topic
        new_topic_id = new_topic.id

        # create linked_topic record
        LinkedTopic.create!(topic_id: new_topic_id, original_topic_id: original_topic_id, sequence: sequence)

        # copy over topic tracking state from old topic
        params = {
          old_topic_id: parent_topic_id,
          new_topic_id: new_topic_id
        }
        DB.exec(<<~SQL, params)
          INSERT INTO topic_users(user_id, topic_id, notification_level,
                                  notifications_reason_id)
          SELECT tu.user_id,
                 :new_topic_id AS topic_id,
                 tu.notification_level,
                 tu.notifications_reason_id
          FROM topic_users tu
               JOIN topics t ON (t.id = :new_topic_id)
          WHERE tu.topic_id = :old_topic_id
            AND tu.notification_level != 1
          ON CONFLICT (topic_id, user_id) DO NOTHING
        SQL

        # add moderator post to old topic
        parent_topic.add_moderator_post(system_user, I18n.t('create_linked_topic.moderator_post_raw', new_title: "[#{new_topic_title}](#{new_topic.url})"))
      end
    end
  end
end
