require "rails_helper"

# Auxiliar method to get the URL format used in this spec file.
def get_url(repo, tag)
  "http://registry.test.lan/v2/#{repo}/manifests/#{tag}"
end

describe Repository do

  it { should belong_to(:namespace) }
  it { should have_many(:tags) }
  it { should have_many(:stars) }

  describe "starrable behaviour" do
    let(:user) { create(:user) }
    let(:repository) { create(:repository) }
    let(:star) { create(:star, user: user, repository: repository) }
    let(:other_user) { create(:user) }

    it "should identify if it is already starred by a user" do
      expect(star.repository.starred_by?(user)).to be true
      expect(star.repository.starred_by?(other_user)).to be false
    end

    it "should be starrable by a user" do
      repository.star(user)
      expect(repository.starred_by?(user)).to be true
      expect(repository.starred_by?(other_user)).to be false
    end

    it "should be unstarrable by a user" do
      repository = star.repository
      repository.unstar(user)
      expect(repository.starred_by?(user)).to be false
      expect(repository.starred_by?(other_user)).to be false
    end
  end

  describe "handle push event" do

    let(:tag_name) { "latest" }
    let(:repository_name) { "busybox" }
    let(:registry) { create(:registry) }
    let(:user) { create(:user) }

    context "event does not match regexp of manifest" do

      let(:event) do
        e = build(:raw_push_manifest_event).to_test_hash
        e["target"]["repository"] = repository_name
        e["target"]["url"] = "http://registry.test.lan/v2/#{repository_name}/wrong/#{tag_name}"
        e["request"]["host"] = registry.hostname
        e
      end

      it "sends event to logger" do
        error_msg =
          "Cannot find tag inside of event url: http://registry.test.lan/v2/busybox/wrong/latest"
        expect(Rails.logger).to receive(:error).with(error_msg)
        expect do
          Repository.handle_push_event(event)
        end.to change(Repository, :count).by(0)
      end

    end

    context "event comes from an unknown registry" do
      before :each do
        @event = build(:raw_push_manifest_event).to_test_hash
        @event["target"]["repository"] = repository_name
        @event["target"]["url"] = get_url(repository_name, tag_name)
        @event["request"]["host"] = "unknown-registry.test.lan"
        @event["actor"]["name"] = user.username
      end

      it "sends event to logger" do
        expect(Rails.logger).to receive(:info)
        expect do
          Repository.handle_push_event(@event)
        end.to change(Repository, :count).by(0)
      end
    end

    context "event comes from an unknown user" do
      before :each do
        @event = build(:raw_push_manifest_event).to_test_hash
        @event["target"]["repository"] = repository_name
        @event["target"]["url"] = get_url(repository_name, tag_name)
        @event["request"]["host"] = registry.hostname
        @event["actor"]["name"] = "a_ghost"
      end

      it "sends event to logger" do
        expect(Rails.logger).to receive(:error)
        expect do
          Repository.handle_push_event(@event)
        end.to change(Repository, :count).by(0)
      end

    end

    context "when dealing with a top level repository" do
      before :each do
        @event = build(:raw_push_manifest_event).to_test_hash
        @event["target"]["repository"] = repository_name
        @event["target"]["url"] = get_url(repository_name, tag_name)
        @event["request"]["host"] = registry.hostname
        @event["actor"]["name"] = user.username
      end

      context "when the repository is not known by Portus" do
        it "should create repository and tag objects" do
          repository = nil
          expect do
            repository = Repository.handle_push_event(@event)
          end.to change(Namespace, :count).by(0)

          expect(repository).not_to be_nil
          expect(Repository.count).to eq 1
          expect(Tag.count).to eq 1

          expect(repository.namespace).to eq(registry.global_namespace)
          expect(repository.name).to eq(repository_name)
          expect(repository.tags.count).to eq 1
          expect(repository.tags.first.name).to eq tag_name
          expect(repository.tags.find_by(name: tag_name).author).to eq(user)
        end

        it "tracks the event" do
          repository = nil
          expect do
            repository = Repository.handle_push_event(@event)
          end.to change(PublicActivity::Activity, :count).by(1)

          activity = PublicActivity::Activity.last
          expect(activity.key).to eq("repository.push")
          expect(activity.owner).to eq(user)
          expect(activity.trackable).to eq(repository)
          expect(activity.recipient).to eq(repository.tags.last)
          expect(repository.tags.find_by(name: tag_name).author).to eq(user)
        end
      end

      context "when a new version of an already known repository" do
        before :each do
          repository = create(:repository, name:      repository_name,
                                           namespace: registry.global_namespace)
          repository.tags << Tag.new(name: "1.0.0")
        end

        it "should create a new tag" do
          repository = nil
          expect do
            repository = Repository.handle_push_event(@event)
          end.to change(Namespace, :count).by(0)

          expect(repository).not_to be_nil
          expect(Repository.count).to eq 1
          expect(Tag.count).to eq 2

          expect(repository.namespace).to eq(registry.global_namespace)
          expect(repository.name).to eq(repository_name)
          expect(repository.tags.count).to eq 2
          expect(repository.tags.map(&:name)).to include("1.0.0", tag_name)
          expect(repository.tags.find_by(name: tag_name).author).to eq(user)
        end

        it "tracks the event" do
          repository = nil
          expect do
            repository = Repository.handle_push_event(@event)
          end.to change(PublicActivity::Activity, :count).by(1)

          activity = PublicActivity::Activity.last
          expect(activity.key).to eq("repository.push")
          expect(activity.owner).to eq(user)
          expect(activity.recipient).to eq(repository.tags.find_by(name: tag_name))
          expect(activity.trackable).to eq(repository)
          expect(repository.tags.find_by(name: tag_name).author).to eq(user)
        end
      end

      context "re-tagging of a known image from one namespace to another" do
        let(:repository_namespaced_name) { "portus/busybox" }
        let(:admin) { create(:admin) }

        before :each do
          team_user = create(:team, owners: [admin])
          @ns = create(:namespace, name: "portus", team: team_user, registry: registry)
          create(:repository, name: "busybox", namespace: registry.global_namespace)
        end

        it "preserves the previous namespace" do
          event = @event
          event["target"]["repository"] = repository_namespaced_name
          event["target"]["url"] = get_url(repository_namespaced_name, tag_name)
          Repository.handle_push_event(event)

          repos = Repository.all.order("id ASC")
          expect(repos.count).to be(2)
          expect(repos.first.namespace.id).to be(registry.global_namespace.id)
          expect(repos.last.namespace.id).to be(@ns.id)
        end
      end
    end

    context "not global repository" do
      let(:namespace_name) { "suse" }

      before :each do
        name = "#{namespace_name}/#{repository_name}"

        @event = build(:raw_push_manifest_event).to_test_hash
        @event["target"]["repository"] = name
        @event["target"]["url"] = get_url(name, tag_name)
        @event["request"]["host"] = registry.hostname
        @event["actor"]["name"] = user.username
      end

      context "when the namespace is not known by Portus" do
        it "does not create the namespace" do
          repository = Repository.handle_push_event(@event)
          expect(repository).to be_nil
        end
      end

      context "when the namespace is known by Portus" do
        before :each do
          @namespace = create(:namespace, name: namespace_name, registry: registry)
        end

        it "should create repository and tag objects when the repository is unknown to portus" do
          repository = Repository.handle_push_event(@event)

          expect(repository).not_to be_nil
          expect(Repository.count).to eq 1
          expect(Repository.count).to eq 1
          expect(Tag.count).to eq 1

          expect(repository.namespace.name).to eq(namespace_name)
          expect(repository.name).to eq(repository_name)
          expect(repository.tags.count).to eq 1
          expect(repository.tags.first.name).to eq tag_name
          expect(repository.tags.find_by(name: tag_name).author).to eq(user)
        end

        it "should create a new tag when the repository is already known to portus" do
          repository = create(:repository, name: repository_name, namespace: @namespace)
          repository.tags << Tag.new(name: "1.0.0")

          repository = Repository.handle_push_event(@event)

          expect(repository).not_to be_nil
          expect(Repository.count).to eq 1
          expect(Repository.count).to eq 1
          expect(Tag.count).to eq 2

          expect(repository.namespace.name).to eq(namespace_name)
          expect(repository.name).to eq(repository_name)
          expect(repository.tags.count).to eq 2
          expect(repository.tags.map(&:name)).to include("1.0.0", tag_name)
          expect(repository.tags.find_by(name: tag_name).author).to eq(user)
        end
      end
    end
  end

  describe "create_or_update" do
    let!(:registry)    { create(:registry) }
    let!(:owner)       { create(:user) }
    let!(:team)        { create(:team, owners: [owner]) }
    let!(:namespace)   { create(:namespace, team: team) }
    let!(:repo1)       { create(:repository, name: "repo1", namespace: namespace) }
    let!(:repo2)       { create(:repository, name: "repo2", namespace: namespace) }
    let!(:tag1)        { create(:tag, name: "tag1", repository: repo1) }
    let!(:tag2)        { create(:tag, name: "tag2", repository: repo2) }
    let!(:tag3)        { create(:tag, name: "tag3", repository: repo2) }

    it "adds and deletes tags accordingly" do
      # Removes the existing tag and adds two.
      repo = { "name" => "#{namespace.name}/repo1", "tags" => ["latest", "0.1"] }
      repo = Repository.create_or_update!(repo)
      expect(repo.id).to eq repo1.id
      expect(repo.tags.map(&:name).sort).to match_array(["0.1", "latest"])

      # Just adds a new tag.
      repo = { "name" => "#{namespace.name}/repo2",
               "tags" => ["latest", tag2.name, tag3.name] }
      repo = Repository.create_or_update!(repo)
      expect(repo.id).to eq repo2.id
      ary = [tag2.name, tag3.name, "latest"].sort
      expect(repo.tags.map(&:name).sort).to match_array(ary)

      # Create repo and tags.
      repo = { "name" => "busybox", "tags" => ["latest", "0.1"] }
      repo = Repository.create_or_update!(repo)
      expect(repo.name).to eq "busybox"
      expect(repo.tags.map(&:name).sort).to match_array(["0.1", "latest"])
    end
  end
end
