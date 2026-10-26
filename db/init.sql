-- Capstone 1 - The Voting App
-- Database initialization script for PostgreSQL
-- Creates the votes table with proper indexing for the voting application

-- Create votes table
CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    voter_id VARCHAR(255) NOT NULL,
    vote VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create index on voter_id for duplicate vote prevention
CREATE INDEX IF NOT EXISTS idx_votes_voter_id ON votes(voter_id);

-- Create index on vote for tally queries
CREATE INDEX IF NOT EXISTS idx_votes_vote ON votes(vote);

-- Create index on created_at for time-based queries
CREATE INDEX IF NOT EXISTS idx_votes_created_at ON votes(created_at);

-- Grant permissions to postgres user (default)
GRANT ALL PRIVILEGES ON TABLE votes TO postgres;
GRANT USAGE, SELECT ON SEQUENCE votes_id_seq TO postgres;

-- Insert initial test data (optional - for verification)
-- INSERT INTO votes (voter_id, vote) VALUES ('test-voter-1', 'Cats');
-- INSERT INTO votes (voter_id, vote) VALUES ('test-voter-2', 'Dogs');

-- Verify table creation
\dt votes