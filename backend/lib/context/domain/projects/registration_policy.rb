# frozen_string_literal: true

module Context
  module Domain
    module Projects
      # Decides whether a project registration's roots may be approved.
      #
      # Plan §1.2: a project is identified by a stable key, never by a path or a
      # Git remote. In version 1 a root or worktree has exactly one active
      # project owner, so a root that is, contains or sits inside another
      # project's approved root is refused rather than silently shared. A
      # checked-in descriptor is a discovery hint: a mismatch is reported, and
      # it grants nothing either way.
      class RegistrationPolicy
        ABSOLUTE = %r{\A(/|[A-Za-z]:[\\/])}
        TRAVERSAL = %r{(\A|[\\/])\.\.([\\/]|\z)}

        Result = Data.define(:project_key, :roots, :descriptor_matches, :warnings)

        # existing_roots: [{ "project_key" => ..., "root_path" => ... }] already
        # approved in this installation, supplied by the caller's query.
        def call(registration:, existing_roots: [])
          roots = registration.roots.map { |root| normalize(root) }
          reject_duplicates!(roots)
          reject_overlaps!(roots, existing_roots, registration.project_key)
          Result.new(
            project_key: registration.project_key,
            roots: roots.freeze,
            descriptor_matches: descriptor_matches?(registration),
            warnings: warnings_for(registration).freeze
          )
        end

        private

        def normalize(root)
          path = root.fetch("root_path")
          Contracts::Validator.invalid!("roots.root_path", "must_be_absolute") unless ABSOLUTE.match?(path)
          Contracts::Validator.invalid!("roots.root_path", "path_traversal") if TRAVERSAL.match?(path)
          root.merge("root_path" => path.tr("\\", "/").chomp("/")).freeze
        end

        def reject_duplicates!(roots)
          identities = roots.map { |root| [root["repository_key"], root["worktree_key"]] }
          Contracts::Validator.invalid!("roots", "duplicate_repository_worktree") if identities.uniq.length != identities.length

          paths = roots.map { |root| root["root_path"] }
          Contracts::Validator.invalid!("roots", "duplicate_root_path") if paths.uniq.length != paths.length
        end

        def reject_overlaps!(roots, existing_roots, project_key)
          foreign = existing_roots.reject { |root| root["project_key"] == project_key }
          roots.each do |root|
            clash = foreign.find { |other| overlapping?(root["root_path"], other["root_path"].to_s.tr("\\", "/").chomp("/")) }
            next unless clash

            raise Errors::ScopeDenied.new(details: { field: "roots.root_path", reason: "root_owned_by_another_project" })
          end
        end

        # Equal paths, or either one containing the other. Comparison is on
        # declared paths only; resolving symlinks and confirming the bytes on
        # disk is the host's job, not a decision this policy can make.
        def overlapping?(candidate, other)
          return true if candidate == other

          candidate.start_with?("#{other}/") || other.start_with?("#{candidate}/")
        end

        def descriptor_matches?(registration)
          descriptor = registration.descriptor
          return nil if descriptor.nil?

          descriptor["project_key"] == registration.project_key
        end

        def warnings_for(registration)
          warnings = []
          if descriptor_matches?(registration) == false
            warnings << { code: "descriptor_project_key_mismatch", detail: "checked-in descriptor names a different project", count: 1 }
          end
          if registration.stack_profile.values.all?(&:empty?)
            warnings << { code: "empty_stack_profile", detail: "no global guidance can be matched by applicability", count: 1 }
          end
          warnings
        end
      end
    end
  end
end
