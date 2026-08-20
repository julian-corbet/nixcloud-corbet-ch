#
# The cluster catalogue: what nixcloud's cluster-side applications ARE.
#
# ── THE SUBJECT ────────────────────────────────────────────────────────────────────────────────
#
# Somebody's documents, and the machinery that keeps them in one place and gets them to whichever
# device is asking. A sync-and-share platform is the obvious member; so is the transfer daemon
# that pulls a folder out of a vendor's cloud, because the file is the same file and the operator
# reaching for either is answering the same question -- where do my documents live and who can
# reach them.
#
# What does NOT belong here, even though the word "cloud" would stretch over it: an object store
# (bytes with no notion of a document), a chat archive, a photo pipeline, a backup tier. Those are
# other repositories' subjects. Stretching a catalogue over everything adjacent to its name is how
# it stops meaning anything.
#
# ── WHAT IS KNOWLEDGE AND WHAT IS A VALUE ──────────────────────────────────────────────────────
#
# Everything in this file is true of the software wherever anyone runs it: the port it listens on,
# the directory it writes INSIDE the container, which variables carry an address it must be told,
# how patient a probe has to be before a slow start counts as a failure, what it stops doing when
# nobody is looking. Nothing here names a host, a node, a namespace, a network, a directory on
# somebody's disk or a credential -- those are one deployment's facts and they arrive from the
# consumer.
#
# The split is enforced rather than trusted. `state` here is the path INSIDE the container and
# what backs it can only come from a declaration; `requires` names the VARIABLES that carry an
# external service's address and never a value for one; `credentials` names the VARIABLES a
# password arrives in and never a password; `image` is a repository with no tag, because which
# build runs is a deployment's decision and a digest is one deployment's proof of what it
# actually pulled.
#
# NAMING A VARIABLE IS NOT CARRYING A SECRET, and `credentials` is where that distinction earns
# its keep. Which variable an application reads its database password out of is written in that
# application's own documentation and is true of every installation of it; the password is one
# deployment's, arrives from a Secret, and nothing in this repository may hold one. Before this
# field existed the catalogue could only describe the half it was allowed to know in PROSE, and
# a sentence in a note is not something a render can check.
#
# ── WHY THE ENTRIES ARE SHAPED LIKE THIS ───────────────────────────────────────────────────────
#
# THIS DOMAIN'S APPLICATIONS ARE NOT ONE PROCESS EACH. A tool with a web face and a database file
# can be described by an image, a port and a directory. A document cloud usually cannot: one of
# these serves FastCGI and has never spoken HTTP in its life, so the port a browser reaches is on
# a web front sharing its pod, and the probe that decides when traffic arrives belongs to THAT
# container. So a catalogue entry describes the app's own container AND the containers beside it,
# each with its own ports, its own mounts and its own probes -- which is exactly the shape the app
# grammar takes, and the only shape in which "port 8080" is a true statement about anything.
#
# A DIRECTORY IS MOUNTED MORE THAN ONCE. Two of the three mount one curated tree at several paths
# -- a config view carved out of a state directory, one shared code tree read three different ways
# by three containers. So `state.<key>` carries a LIST of mounts rather than a single path, and
# companions carry their own view of the same volume. A volume is a pod fact; a mount is a
# container fact; the two are not the same field.
#
# EVERY FIELD IS WRITTEN OUT, including the empty ones. `state = { }`, `requires = { }`,
# `companions = { }` and the rest are stated rather than omitted: the assertions read those
# attributes, so an absent one throws where it should have asserted "none". An entry that says
# nothing about whether it writes anything is the entry that quietly gets no volume.
#
# WHAT IS DELIBERATELY ABSENT. Resource requests and limits: a CPU share and a memory ceiling are
# a measurement of one deployment's load, not a property of the software, and copying somebody
# else's numbers here would dress a guess as knowledge. They are absent HERE and expressible in a
# declaration -- `resources` and `companionResources` in the module -- which is the whole shape of
# this split rather than an admission that nobody may state them. Replica counts, node selectors,
# identities and addresses: fleet facts, every one of them, and the grammar refuses several of
# them outright.
{}:
{
  applications = {
    # ─────────────────────────────────────────────────────────────────────────────────────────
    opencloud = {
      # The ex-ownCloud team's fork of the oCIS line. `-rolling` is a CHANNEL, not a flavour: the
      # 7.x series ships from this repository while the plain `opencloud` repository trails well
      # behind it. Which channel a deployment tracks is its own decision; this is the one the
      # repository's own release notes point a current installation at.
      image = "opencloudeu/opencloud-rolling";

      # It is a server, and the image's entrypoint is not. Stated because leaving it out starts
      # the binary with no subcommand, which prints help and exits 0 -- a container that "ran".
      command = [ "opencloud" "server" ];
      args = [ ];

      # ONE PORT for everything. The proxy service serves the web UI, the CS3 API, and -- when a
      # deployment turns the collaboration service on -- the WOPI endpoints too. There is no
      # separate document-editing host to route, which is the single biggest difference from
      # running the same feature as its own deployment.
      ports.http = { number = 9200; publish = true; servicePort = null; };
      primaryPort = "http";
      unprivileged = true;

      # TWO DIRECTORIES, and the split is the whole design rather than tidiness.
      #
      #   state     -- everything opaque: the internal identity store, the embedded message
      #                bus's key-value cache, thumbnails, and the generated configuration. That
      #                configuration is a SUBDIRECTORY of the same tree, and the binary insists
      #                on reading it from a different path, which is why one volume lands twice.
      #   userfiles -- the user spaces themselves, and under the POSIX driver these are PLAIN
      #                FILES: a directory per space, a file per file, readable by anything else
      #                that can see the tree. That is the property that makes this app worth
      #                running over an opaque-blob alternative, and it is also why the two must
      #                not be one volume -- a backup of somebody's documents and a cache of
      #                thumbnails do not want the same treatment.
      #
      # Declaring durable state is also what puts the Deployment on `Recreate`, which this app
      # requires anyway: one writer on the POSIX tree, and one on the embedded bus and identity
      # store that live in the other directory.
      state = {
        state.mounts = [
          { mountPath = "/var/lib/opencloud"; }
          { mountPath = "/etc/opencloud"; subPath = "config"; }
        ];
        userfiles.mounts = [{ mountPath = "/var/lib/opencloud/storage/users"; }];
      };

      # Container-internal facts only. Every one of these is either a path inside the container,
      # the loopback address of a service this same process runs, or the name of a driver the
      # `state` declaration above is only true under.
      env = {
        # The proxy binds every interface on the port declared above. Not an address: a container
        # binding 0.0.0.0 is a statement about the container, not about a network.
        PROXY_HTTP_ADDR = "0.0.0.0:9200";

        # THE DRIVER THE `userfiles` CLAIM DEPENDS ON. Under the POSIX driver the user spaces are
        # ordinary files on an ordinary tree; under the decomposed driver the same directory is an
        # opaque blob store with a node database beside it, and every sentence above about plain
        # readable files stops being true. The catalogue cannot describe the volume without
        # stating which of the two it describes.
        STORAGE_USERS_DRIVER = "posix";
        STORAGE_USERS_POSIX_ROOT = "/var/lib/opencloud/storage/users";

        # The single binary's ~20 services find each other through a message bus it runs itself,
        # on loopback, inside its own container. Nothing external is being named here and nothing
        # external can be: change these and the process stops being able to talk to itself.
        MICRO_REGISTRY_ADDRESS = "127.0.0.1:9233";
        STORAGE_USERS_ID_CACHE_STORE = "nats-js-kv";
        STORAGE_USERS_ID_CACHE_STORE_NODES = "127.0.0.1:9233";
      };

      # WHAT IT MUST BE TOLD, because it cannot discover it and will not invent it.
      requires = {
        # It runs no usable identity provider of its own in this shape -- the bundled one is
        # excluded from the service list on any installation using external sign-in, and role
        # assignment is driven off a claim in the external provider's token. Given no issuer it
        # does not fall back to local accounts; it fails the metadata fetch at startup and
        # authenticates nobody.
        identity = [ "OC_OIDC_ISSUER" "WEB_OIDC_METADATA_URL" "WEB_OIDC_CLIENT_ID" ];
      };

      # NONE, and that is a real statement rather than an empty field. The internal secrets every
      # one of the bundled services authenticates to its neighbours with are GENERATED by the
      # first-boot command below, into the persisted configuration -- so they are not handed to
      # this application, they are made by it and then kept. The one credential a deployment does
      # supply, the client secret of a confidential OIDC client, is not used in this shape: the
      # web front is a public client and the proxy verifies tokens without one.
      credentials = { };

      # WHAT IT IS REACHED AT, in its own words. Both variables end up in redirect URIs handed to
      # a browser and in the callback address handed to a document editor, so a wrong value is not
      # a cosmetic mismatch: sign-in returns to the wrong place and editing sessions never call
      # back. It cannot derive them -- everything it sees is a proxied request.
      publicIdentity = [ "OC_URL" "OC_DOMAIN" ];

      # THE SOCKET, NOT A PAGE. `/` answers with a redirect chain into the sign-in dance, so an
      # HTTP probe there measures the identity provider's availability rather than this app's.
      # "the port is open" is the honest cheap question.
      #
      # The budget is what a ~20-service single binary needs on a cold start with a config
      # generation in front of it: twenty seconds before the first question, then five minutes of
      # patience. The usual way to put an app like this into a restart loop is to leave these at
      # their defaults and call a slow start a failure.
      readiness = {
        path = null;
        initialDelaySeconds = 20;
        periodSeconds = 10;
        failureThreshold = 30;
      };
      liveness = {
        path = null;
        initialDelaySeconds = 90;
        periodSeconds = 30;
        failureThreshold = 6;
      };

      # FIRST BOOT GENERATES A CONFIGURATION, and it has to happen before the server starts rather
      # than as part of starting it. The command runs the app's OWN image against the app's OWN
      # volume, which is precisely the case an init container is for -- an overlay would restate
      # both. It is guarded rather than conditional because re-running it against an existing
      # configuration is an error, not a refresh: the generated file also carries the internal
      # secrets every one of the bundled services authenticates to its neighbours with, and
      # regenerating those orphans everything already stored.
      init = [
        {
          name = "init";
          image = null; # the app's own
          command = [ "sh" "-c" "test -f /etc/opencloud/opencloud.yaml || opencloud init --insecure yes" ];
          args = [ ];
          env = { };
          mounts.state = [{ mountPath = "/etc/opencloud"; subPath = "config"; }];
          unprivileged = true;
        }
      ];

      companions = { };

      # NOT SAFE TO SLEEP. See the note.
      sleepSafe = false;

      note = ''
        A file sync-and-share platform: spaces, sharing links, desktop and mobile clients, and a
        web UI, served by ONE binary that runs about twenty internal services in one process.

        THE POSIX DRIVER IS THE REASON TO CHOOSE IT. User files are stored as plain files in a
        plain directory tree, one directory per space, rather than as content-addressed blobs
        with a database explaining what they are. Anything else that can see the tree -- a file
        share, a backup that walks directories, a person with a shell -- sees documents. The
        alternative driver is faster and gives that up entirely, which is a real trade and not
        this file's to make; what this file records is that the `userfiles` volume above is only
        the thing described while the POSIX driver is the one running.

        IT AUTHENTICATES NOBODY BY ITSELF. Sign-in is external, and so is the group claim that
        decides who is an administrator: with the role-assignment driver reading a claim, a user
        matching no role is not a read-only user, they are refused. The consequence for a
        deployment is that the role mapping is a piece of configuration somebody must supply, and
        the variables that identify the provider are `requires.identity` above. Their VALUES name
        one installation's identity provider; an issuer URL and a client id are not credentials,
        and they are still not knowledge.

        COLLABORATIVE EDITING RUNS IN-PROCESS, when a deployment asks for it -- the collaboration
        service is added to the run list rather than deployed separately, and it then needs the
        address of a document editor this app does not run. That switch and that address are both
        a deployment's, which is why neither is in `env` here: an installation with no editor is
        a perfectly good installation with read-only previews.

        WATCHING THE FILESYSTEM IS OPTIONAL AND CHANGES WHAT SLEEPING MEANS. It can watch the
        POSIX tree for writes that did not come through it -- a file dropped over a share, an
        upload from a script -- and pick them up live. A deployment that turns that on has an
        application whose job includes noticing things while nobody is looking.

        IT SHOULD NOT SLEEP. Even with the watcher off, this is the front door to somebody's
        documents: desktop clients hold long-lived connections to it, and a cold start here is
        the five-minute budget above rather than a second. `sleepSafe = false` records that;
        whether a deployment overrides it is its own call, and the module warns rather than
        refuses.
      '';
    };

    # ─────────────────────────────────────────────────────────────────────────────────────────
    nextcloud = {
      # The official image, and the `-fpm` flavour of its tag specifically. THE FLAVOUR IS PART OF
      # THIS ENTRY'S TRUTH: the plain tag ships Apache and serves HTTP on 80, while `-fpm` ships
      # a FastCGI process and serves nothing a browser can read. Everything below -- the port
      # table, the web companion, which container the readiness probe lives on -- describes the
      # `-fpm` one. A deployment that supplies a non-fpm tag gets a pod whose web front proxies
      # FastCGI to an HTTP server.
      image = "nextcloud";
      command = [ ];
      args = [ ];

      # THE APP'S OWN CONTAINER SPEAKS FASTCGI AND NOTHING ELSE. The port is real -- a process
      # genuinely listens on it -- and it must never reach a Service: a Service pointed at a
      # FastCGI socket is an application that runs and is unreachable, and the browser sees a
      # binary handshake instead of a login page.
      ports.fpm = { number = 9000; publish = false; servicePort = null; };
      primaryPort = "fpm";
      unprivileged = true;

      # TWO DIRECTORIES, and unusually the CODE is one of them.
      #
      #   html -- the application itself: PHP code, `config/`, installed apps. Nextcloud upgrades
      #           itself in place and installs apps into this tree at runtime, so it is state
      #           even though it starts life as the contents of an image. It is also what the
      #           three containers share: they are three processes over one installation, not
      #           three copies of it.
      #   data -- the user files, previews and per-instance application data.
      #
      # Two, not one, because they have nothing else in common: one is an installation that a
      # release replaces and the other is documents that must outlive every release.
      state = {
        html.mounts = [{ mountPath = "/var/www/html"; }];
        data.mounts = [{ mountPath = "/mnt/ncdata"; }];
      };

      env = {
        # Container-internal, and it must agree with the `data` mount above: this is the variable
        # the entrypoint writes into the configuration as the data directory, and pointing it
        # anywhere else means the volume is mounted and unused while the pod writes documents to
        # its own ephemeral filesystem.
        NEXTCLOUD_DATA_DIR = "/mnt/ncdata";
      };

      requires = {
        # IT DOES NOT SHIP A DATABASE. SQLite exists as an option and is unusable for anything
        # with more than one person in it -- the file is a global write lock. The variables below
        # are the official image's own contract for a PostgreSQL server. The PASSWORD is not among
        # them and never will be, because it is not an address: it is `credentials.database`, and
        # the difference between the two lists is the difference between a value a declaration
        # types out and a value a declaration may only NAME a Secret for.
        database = [ "POSTGRES_HOST" "POSTGRES_DB" "POSTGRES_USER" ];
      };

      # THE VARIABLE, NOT THE PASSWORD. `POSTGRES_PASSWORD` is the official image's own name for
      # the credential it authenticates to that server with -- as true of every installation as
      # the three variables above -- and it is required rather than optional because the entrypoint
      # writes it into the generated configuration on first boot and the application has no other
      # way to reach its own database. Naming it here is what lets a render refuse a declaration
      # that forgot it; carrying its value here would be the thing this repository must never do.
      credentials.database = [ "POSTGRES_PASSWORD" ];

      # THE TRUSTED-DOMAIN CHECK IS NOT ADVISORY. Told nothing, Nextcloud answers every request
      # from an unrecognised host with a refusal page instead of the application -- which is
      # exactly what a fresh deployment behind a proxy looks like when this is forgotten, and it
      # reads as "the app is broken" rather than "the app has not been told its own name".
      publicIdentity = [ "NEXTCLOUD_TRUSTED_DOMAINS" ];

      # NO PROBE ON THE APP'S OWN CONTAINER. Kubernetes holds a pod out of its Service until every
      # container is ready, so in a pod with a web front it is the FRONT's probe that decides when
      # traffic arrives; a second probe here would only add a way for the pod to be held back. The
      # honest place for it is `companions.web` below.
      readiness = null;
      liveness = null;

      init = [ ];

      # THREE PROCESSES OVER ONE INSTALLATION.
      companions = {
        # The web front. The application speaks FastCGI, so something has to speak HTTP to the
        # world and FastCGI to the application over loopback, and it needs the code tree to serve
        # static assets from -- READ-ONLY, because serving files is not editing them.
        #
        # The unprivileged image is the deliberate one: it binds 8080 rather than 80, and a
        # process that cannot bind a privileged port is a process that does not need to run as
        # root. The Service carries 80 anyway -- `servicePort` is what makes the container's
        # honest port and the Service's conventional one two different numbers instead of a
        # compromise between them.
        web = {
          image = "nginxinc/nginx-unprivileged";
          command = [ ];
          args = [ ];
          env = { };
          ports.http = { number = 8080; publish = true; servicePort = 80; };
          primaryPort = "http";
          mounts.html = [{ mountPath = "/var/www/html"; readOnly = true; }];
          unprivileged = true;

          # THE PROBE THAT DECIDES WHEN TRAFFIC ARRIVES, and it is an HTTP one because here there
          # is a cheap endpoint worth asking: the status page answers from the application
          # through this front, so a pass means the whole chain works rather than that a socket
          # is open.
          #
          # KNOWN LIMITATION, recorded rather than papered over: an installation whose
          # trusted-domain list does not include the name the probe arrives as needs the probe to
          # send an explicit Host header, and the app grammar has no term for probe headers. A
          # deployment in that position adds the header in its own overlay; this catalogue does
          # not invent a term it cannot render.
          readiness = {
            path = "/status.php";
            initialDelaySeconds = 0;
            periodSeconds = 10;
            failureThreshold = 6;
          };
          liveness = null;
        };

        # The realtime channel. Without it, every connected client falls back to polling the
        # server every few seconds; with it they hold one connection and are told when something
        # changed. It is a native binary that ships INSIDE the application's own installed apps
        # rather than in any image, which is why it runs the app's image and waits for the file
        # to exist: on a first boot the application has not unpacked it yet, and a container that
        # exits because a path is missing takes the whole pod into a crash loop for a reason that
        # has nothing to do with either process.
        realtime = {
          image = null; # the app's own -- the binary lives in the shared installation, not in an image
          command = [
            "sh"
            "-c"
            "until [ -f /var/www/html/custom_apps/notify_push/bin/x86_64/notify_push ]; do sleep 3; done; exec /var/www/html/custom_apps/notify_push/bin/x86_64/notify_push /var/www/html/config/config.php"
          ];
          args = [ ];
          env = {
            PORT = "7867";
            # The web front, over loopback, inside this pod. A container reaching its neighbour
            # by loopback is a fact about a container and not about a network, which is why the
            # grammar's address guard allows exactly this and nothing that looks like it.
            NEXTCLOUD_URL = "http://localhost:8080";
            ALLOW_SELF_SIGNED = "true";
          };
          ports.push = { number = 7867; publish = false; servicePort = null; };
          primaryPort = "push";
          mounts.html = [{ mountPath = "/var/www/html"; }];
          unprivileged = true;
          readiness = null;
          liveness = null;
        };
      };

      # NOT SAFE TO SLEEP. See the note.
      sleepSafe = false;

      note = ''
        The largest self-hosted document cloud there is: files, sharing, calendars, contacts, and
        an application ecosystem on top of them. Three processes over one installation -- the
        application, a web front, and a realtime channel -- plus work that happens on a timer.

        MINED FROM A DECLARATION IN THE OLDER SHAPE. Unlike its two neighbours here, the live
        deployment this entry describes is not written against the app grammar at all: it is a
        hand-written manifest passed through the raw-YAML escape hatch, and every fact above --
        which containers exist, which ports they hold, which directories they share, how the
        realtime binary is started -- was read off that manifest rather than off a declaration.
        Two consequences worth stating out loud. First, nothing checked those facts before this
        file existed, so this entry is the first time they have been typed. Second, some of what
        the manifest does has no term in the grammar and is therefore absent here rather than
        approximated: a probe that carries a Host header, and an init container that refuses to
        start the pod when the crypto-identity overlay is missing.

        THE CRYPTO IDENTITY IS THE THING TO BE FRIGHTENED OF. An installation has three values --
        an instance id, a secret and a password salt -- that live in its configuration and nowhere
        else. Lose them and the installation still starts: single sign-on stops working, every
        application password and device token is invalid, anything server-side-encrypted is
        unreadable, and the per-instance data directory is orphaned under a name nothing looks for
        any more. It fails OPEN, which is why a deployment carrying those values in a Secret
        overlay should assert their presence before the application starts rather than after.

        IT NEEDS A DATABASE AND A CACHE, AND OWNS NEITHER. The database is `requires.database`
        above. The cache is a distributed one used for file locking as well as caching, and it is
        configured in the application's own configuration file rather than through the
        environment -- so there is no variable this catalogue can name for it, and this sentence
        is the record of that instead of an invented one. Both are somebody else's subject: a
        database engine and a cache are not document clouds, and cataloguing them here to make one
        entry self-contained would be the first stretch that ends with a catalogue meaning
        nothing.

        WORK HAPPENS ON A TIMER. Background jobs -- previews, cleanups, federation retries,
        notification delivery -- run on a schedule outside any request. The usual shape is a
        separate scheduled workload against the same directories, which is a second workload and
        not a term of this entry; what belongs here is the consequence, which is that a Nextcloud
        nobody is looking at is not a Nextcloud with nothing to do. `sleepSafe = false`.
      '';
    };

    # ─────────────────────────────────────────────────────────────────────────────────────────
    rclone = {
      image = "rclone/rclone";

      # THE DAEMON, not the one-shot. `rclone` with no subcommand copies nothing and exits; `rcd`
      # is what makes it a long-running remote-control server, and the web GUI is a flag on that
      # server rather than a separate thing to deploy.
      command = [ ];
      args = [
        "rcd"
        "--rc-web-gui"
        "--rc-web-gui-no-open-browser"
        "--rc-addr=:5572"
      ];

      ports.http = { number = 5572; publish = true; servicePort = null; };
      primaryPort = "http";
      unprivileged = true;

      # ONE DIRECTORY, and it holds two different things that both have to survive a restart: the
      # remote definitions, and the web GUI bundle the daemon downloads for itself. See the note
      # for why the second one is not a cache you can afford to lose.
      state = {
        cfg.mounts = [{ mountPath = "/config/rclone"; }];
      };

      env = {
        # Both are container-internal paths and both point INTO the volume above. Neither is a
        # preference.
        RCLONE_CONFIG = "/config/rclone/rclone.conf";
        HOME = "/config/rclone";
      };

      # Nothing. It is told what to do over its own API, and it discovers its remotes by reading
      # the file above -- there is no service it must be handed the address of at startup.
      requires = { };

      # THE TWO VARIABLES THE CONTROL API TAKES ITS BASIC AUTH FROM. Required rather than
      # optional, and the reason is one line above in `args`: the daemon is started WITHOUT
      # `--rc-no-auth`, so this pair is the whole of what stands between the port and every remote
      # definition the daemon holds. A declaration that supplies neither does not get an open
      # installation with a warning -- it gets refused, because for an application whose entire
      # job is holding credentials to other people's storage, "authentication was omitted" is not
      # a state anybody should be able to reach by leaving a line out.
      credentials.rc-auth = [ "RCLONE_RC_USER" "RCLONE_RC_PASS" ];

      # Nothing. It generates no links and issues no redirects; it never needs to know the name
      # it is reached at.
      publicIdentity = [ ];

      # THE SOCKET, NOT A PAGE, and for a sharper reason than the usual one: the control API
      # answers POST and returns 404 to a GET of `/`, and `/` is served by the web GUI bundle,
      # which is not there yet during the exact window a readiness probe is asking. An HTTP probe
      # at `/` therefore reports a perfectly healthy daemon as dead for as long as the bundle
      # takes to arrive, and reports it as dead forever if the bundle cannot be written at all.
      #
      # Five seconds by thirty is a two-and-a-half-minute budget, which is a cold start that
      # includes fetching that bundle over the internet.
      readiness = {
        path = null;
        initialDelaySeconds = 0;
        periodSeconds = 5;
        failureThreshold = 30;
      };
      liveness = {
        path = null;
        initialDelaySeconds = 0;
        periodSeconds = 20;
        failureThreshold = 6;
      };

      init = [ ];
      companions = { };

      # Safe to sleep. See the note.
      sleepSafe = true;

      note = ''
        rclone's remote-control daemon with its web interface: one process that holds a set of
        remote definitions -- vendor clouds, WebDAV endpoints, object stores -- and moves files
        between them on demand, driven by an HTTP API with a browser front end over it.

        WHY IT IS IN THIS CATALOGUE AND NOT AN INFRASTRUCTURE ONE. It is the operator's hand on
        the same documents the other two serve: the thing you reach for to pull a folder out of a
        vendor's cloud, mirror one endpoint into another, or check what is actually in a remote.
        The subject is the file, which is why it sits here.

        AND WHY IT DOES NOT SHARE THEIR NAMESPACE. A transfer daemon has a completely different
        lifecycle from a collaboration platform -- it is restarted, reconfigured and idled
        without anyone caring, while they are things people have open. A namespace is a
        blast-radius boundary, so two lifecycles that never fail together do not belong in one.
        The module below makes each workload name its own namespace precisely because this
        repository's applications do not agree on one.

        IT AUTHENTICATES, AND WEAKLY. The API and the GUI take HTTP basic auth from the two
        variables in `credentials.rc-auth`, and that is the whole of it -- no accounts, no
        sessions, no second factor. Anything that reaches the port and knows the pair can read and
        rewrite every remote definition, which for an app whose entire job is holding credentials
        to other people's storage means the exposure class is not a detail. The pair itself
        arrives from a Secret a declaration NAMES; nothing here can carry one.

        THE HOME DIRECTORY IS LOAD-BEARING, and this is the failure worth writing down. The daemon
        downloads its web GUI bundle at startup and caches it under the user's home directory. In
        a container whose user has no entry in the password file, home defaults to `/` -- which is
        not writable -- so the bundle cannot be written, and the daemon serves NOTHING at `/`
        while the control API underneath keeps answering perfectly. The symptom is a permanent 404
        in a browser and a service that every API-level check calls healthy. Pointing home at the
        already-writable configuration directory fixes it, and as a side effect the bundle then
        survives a restart instead of being re-fetched from the internet on every one.

        IT IS SAFE TO SLEEP, with one caveat that is a deployment's and not this file's. Nothing
        fires on a timer here: the daemon does exactly what it is asked and nothing between
        requests, so at zero replicas no work fails to happen. The caveat is that a transfer
        already running IS work in progress, and an idle timer short enough to catch the gap
        between two API calls can stop one halfway. How long to wait before sleeping is a number
        only the deployment knows.
      '';
    };
  };
}
