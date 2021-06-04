CREATE TABLE devices (
    id VARCHAR(255) NOT NULL,

    identity_cert TEXT NULL,

    serial_number VARCHAR(127) NULL,

    -- If the (iOS, iPadOS) device sent an UnlockToken in the TokenUpdate
    -- TODO: Consider using a TEXT field and encoding the binary
    unlock_token    MEDIUMBLOB NULL,
    unlock_token_at TIMESTAMP  NULL,

    -- The last raw Authenticate for this device
    authenticate    TEXT      NOT NULL,
    authenticate_at TIMESTAMP NOT NULL,
    -- The last raw TokenUpdate for this device
    token_update    TEXT      NULL,
    token_update_at TIMESTAMP NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),

    CHECK (identity_cert IS NULL OR
        SUBSTRING(identity_cert FROM 1 FOR 27) = '-----BEGIN CERTIFICATE-----'),

    CHECK (serial_number IS NULL OR serial_number != ''),
    INDEX (serial_number),

    CHECK (unlock_token IS NULL OR LENGTH(unlock_token) > 0),

    CHECK (authenticate != ''),
    CHECK (token_update IS NULL OR token_update != '')
);


CREATE TABLE users (
    id        VARCHAR(255) NOT NULL,
    device_id VARCHAR(255) NOT NULL,

    user_short_name VARCHAR(255) NULL,
    user_long_name  VARCHAR(255) NULL,

    -- The last raw TokenUpdate for this user
    token_update    TEXT      NULL,
    token_update_at TIMESTAMP NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id, device_id),

    FOREIGN KEY (device_id)
        REFERENCES devices (id)
        ON DELETE CASCADE ON UPDATE CASCADE,

    CHECK (user_short_name IS NULL OR user_short_name != ''),
    CHECK (user_long_name  IS NULL OR user_long_name  != ''),

    CHECK (token_update IS NULL OR token_update != '')
);


/* This table represents enrollments which are an amalgamation of
 * both device and user enrollments.
 */
CREATE TABLE enrollments (
    -- The enrollment ID of this enrollment
    id        VARCHAR(255) NOT NULL,
    -- The "device" enrollment ID of this enrollment. This will be
    -- the same as the `id` field in the case of a "device" enrollment,
    -- or will be the "parent" enrollment for a "user" enrollment.
    device_id VARCHAR(255) NOT NULL,
    -- The "user" enrollment ID of this enrollment. This will be the
    -- same as the `id` field in the case of a "user" enrollment or
    -- NULL in the case of a device enrollment.
    user_id   VARCHAR(255) NULL,

    -- Textual representation of the type of device enrollment.
    type      VARCHAR(31) NOT NULL,

    -- The MDM APNs push trifecta.
    topic      VARCHAR(255) NOT NULL,
    push_magic VARCHAR(127) NOT NULL,
    token_hex  VARCHAR(255) NOT NULL, -- TODO: Perhaps just CHAR(64)?

    enabled BOOLEAN NOT NULL DEFAULT 1,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    CHECK (id != ''),

    FOREIGN KEY (device_id)
        REFERENCES devices (id)
        ON DELETE CASCADE ON UPDATE CASCADE,

    FOREIGN KEY (user_id)
        REFERENCES users (id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    UNIQUE (user_id),

    CHECK (type != ''),
    INDEX (type),

    CHECK (topic != ''),
    CHECK (push_magic != ''),
    CHECK (token_hex != '')
);


/* Commands stand alone. By themsevles they aren't associated with
 * a device, a result (response), etc. Joining other tables is required
 * for more context.
 */
CREATE TABLE commands (
    command_uuid VARCHAR(127) NOT NULL,
    request_type VARCHAR(63)  NOT NULL,
    -- Raw command Plist
    command      TEXT         NOT NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (command_uuid),

    CHECK (command_uuid != ''),
    CHECK (request_type != ''),
    CHECK (SUBSTRING(command FROM 1 FOR 5) = '<?xml')
);


/* Results are enrollment responses to device commands.
 *
 * The choice for the PK being just the enrollment ID and command UUID
 * was under consideration. The PK could have included for example the
 * status in which case we could have separate status updates for
 * a NotNow vs. an Acknowledge. However this might be non-intuitive to
 * then query against to find if a given command had a response or not
 * (i.e. the queue view would be more complicated). In the end this
 * means we lose insight into when NotNows happen once a command is
 * Acknowledged.
 */
CREATE TABLE command_results (
    id           VARCHAR(255) NOT NULL,
    command_uuid VARCHAR(127) NOT NULL,
    status       VARCHAR(31)  NOT NULL,
    result       TEXT         NOT NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id, command_uuid),

    FOREIGN KEY (id)
        REFERENCES enrollments (id)
        ON DELETE CASCADE ON UPDATE CASCADE,

    FOREIGN KEY (command_uuid)
        REFERENCES commands (command_uuid)
        ON DELETE CASCADE ON UPDATE CASCADE,

    -- considering not enforcing these CHECKs to make sure we always
    -- capture results in the case they're malformed.
    CHECK (status != ''),
    INDEX (status),
    CHECK (SUBSTRING(result FROM 1 FOR 5) = '<?xml')
);


CREATE TABLE enrollment_queue (
    id           VARCHAR(255) NOT NULL,
    command_uuid VARCHAR(127) NOT NULL,

    active   BOOLEAN NOT NULL DEFAULT 1,
    priority TINYINT NOT NULL DEFAULT 0,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id, command_uuid),

    FOREIGN KEY (id)
        REFERENCES enrollments (id)
        ON DELETE CASCADE ON UPDATE CASCADE,

    FOREIGN KEY (command_uuid)
        REFERENCES commands (command_uuid)
        ON DELETE CASCADE ON UPDATE CASCADE
);

/* An enrollment's queue is a view into commands, enrollment queued
 * commands, and any results received. Outstanding queue items (i.e.
 * those that have received no result yet) will have a status of NULL
 * (due to the LEFT JOIN against results).
 */
CREATE OR REPLACE VIEW view_queue AS
SELECT
    q.id,
    q.created_at,
    q.active,
    q.priority,
    c.command_uuid,
    c.request_type,
    c.command,
    r.updated_at AS result_updated_at,
    r.status,
    r.result
FROM
    enrollment_queue AS q

        INNER JOIN commands AS c
        ON q.command_uuid = c.command_uuid

        LEFT JOIN command_results r
        ON r.command_uuid = q.command_uuid AND r.id = q.id
ORDER BY
    q.priority DESC,
    q.created_at;


CREATE TABLE push_certs (
    topic VARCHAR(255) NOT NULL,

    cert_pem TEXT NOT NULL,
    key_pem  TEXT NOT NULL,

    /* stale_token is a simple value that coordinates push certificates
     * across the SQL backend. The push service checks this value
     * every time push info is requested. This value should be updated
     * every time a push cert is updated (i.e. renwals) and so all
     * push services using this table will know the certificate has
     * changed and reload it. This is managed by the MySQL backend. */
    stale_token INTEGER NOT NULL,

    PRIMARY KEY (topic),
    CHECK (topic != ''),

    CHECK (SUBSTRING(cert_pem FROM 1 FOR 27) = '-----BEGIN CERTIFICATE-----'),
    CHECK (SUBSTRING(key_pem  FROM 1 FOR  5) = '-----')
);


CREATE TABLE cert_auth_associations (
    id     VARCHAR(255) NOT NULL,
    sha256 CHAR(64)     NOT NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id, sha256),

    CHECK (id != ''),
    CHECK (sha256 != '')
);
