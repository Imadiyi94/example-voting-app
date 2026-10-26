using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Npgsql;
using StackExchange.Redis;

namespace VotingApp.Worker
{
    public class Program
    {
        public static async Task Main(string[] args)
        {
            var host = Host.CreateDefaultBuilder(args)
                .ConfigureAppConfiguration((context, config) =>
                {
                    config.AddEnvironmentVariables();
                })
                .ConfigureServices((context, services) =>
                {
                    services.AddHostedService<VoteProcessor>();
                })
                .ConfigureLogging(logging =>
                {
                    logging.ClearProviders();
                    logging.AddConsole();
                    logging.SetMinimumLevel(LogLevel.Information);
                })
                .Build();

            await host.RunAsync();
        }
    }

    public class VoteProcessor : BackgroundService
    {
        private readonly ILogger<VoteProcessor> _logger;
        private readonly IConfiguration _configuration;
        private IConnectionMultiplexer _redis;
        private IDatabase _db;
        private NpgsqlConnection _pgConnection;

        public VoteProcessor(ILogger<VoteProcessor> logger, IConfiguration configuration)
        {
            _logger = logger;
            _configuration = configuration;
        }

        public override async Task StartAsync(CancellationToken cancellationToken)
        {
            _logger.LogInformation("Starting Vote Processor...");

            // Initialize Redis connection
            var redisHost = _configuration["REDIS_HOST"] ?? "redis";
            var redisPort = int.Parse(_configuration["REDIS_PORT"] ?? "6379");
            var redisConnectionString = $"{redisHost}:{redisPort}";

            _redis = await ConnectionMultiplexer.ConnectAsync(redisConnectionString);
            _db = _redis.GetDatabase();
            _logger.LogInformation($"Connected to Redis at {redisConnectionString}");

            // Initialize PostgreSQL connection
            var dbHost = _configuration["DB_HOST"] ?? "db";
            var dbPort = _configuration["DB_PORT"] ?? "5432";
            var dbName = _configuration["DB_NAME"] ?? "postgres";
            var dbUser = _configuration["DB_USER"] ?? "postgres";
            
            // Read password from file (Docker secret)
            var dbPasswordFile = _configuration["DB_PASSWORD_FILE"] ?? "/run/secrets/db_password";
            var dbPassword = File.Exists(dbPasswordFile) 
                ? File.ReadAllText(dbPasswordFile).Trim() 
                : _configuration["DB_PASSWORD"] ?? "";

            var pgConnectionString = $"Host={dbHost};Port={dbPort};Database={dbName};Username={dbUser};Password={dbPassword};Pooling=true;MinPoolSize=1;MaxPoolSize=10;";

            _pgConnection = new NpgsqlConnection(pgConnectionString);
            await _pgConnection.OpenAsync(cancellationToken);
            _logger.LogInformation($"Connected to PostgreSQL at {dbHost}:{dbPort}");

            // Ensure table exists
            await EnsureTableExistsAsync(cancellationToken);

            await base.StartAsync(cancellationToken);
        }

        private async Task EnsureTableExistsAsync(CancellationToken cancellationToken)
        {
            var createTableSql = @"
                CREATE TABLE IF NOT EXISTS votes (
                    id SERIAL PRIMARY KEY,
                    voter_id VARCHAR(255) NOT NULL,
                    vote VARCHAR(255) NOT NULL,
                    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS idx_votes_voter_id ON votes(voter_id);
                CREATE INDEX IF NOT EXISTS idx_votes_vote ON votes(vote);
                CREATE INDEX IF NOT EXISTS idx_votes_created_at ON votes(created_at);";

            using var cmd = new NpgsqlCommand(createTableSql, _pgConnection);
            await cmd.ExecuteNonQueryAsync(cancellationToken);
            _logger.LogInformation("Votes table verified/created");
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            _logger.LogInformation("Vote Processor started. Polling Redis for votes...");

            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    // Blocking pop from Redis list (blocks until item available or cancelled)
                    var voteEntry = await _db.ListRightPopAsync("votes", CommandFlags.None);
                    
                    if (!voteEntry.IsNullOrEmpty)
                    {
                        await ProcessVoteAsync(voteEntry, stoppingToken);
                    }
                }
                catch (RedisConnectionException ex)
                {
                    _logger.LogError(ex, "Redis connection error. Reconnecting...");
                    await ReconnectRedisAsync(stoppingToken);
                }
                catch (PostgresException ex)
                {
                    _logger.LogError(ex, "PostgreSQL error. Reconnecting...");
                    await ReconnectPostgresAsync(stoppingToken);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Unexpected error in vote processing loop");
                    await Task.Delay(5000, stoppingToken); // Back off on unknown errors
                }
            }
        }

        private async Task ProcessVoteAsync(RedisValue voteEntry, CancellationToken cancellationToken)
        {
            try
            {
                // Explicitly convert RedisValue to string for JSON deserialization
                var json = (string)voteEntry;
                var options = new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
                };
                var voteData = JsonSerializer.Deserialize<VoteData>(json, options);
                
                if (voteData == null || string.IsNullOrEmpty(voteData.VoterId) || string.IsNullOrEmpty(voteData.Vote))
                {
                    _logger.LogWarning("Invalid vote data received, skipping");
                    return;
                }

                // Check for duplicate voter_id
                var checkSql = "SELECT COUNT(1) FROM votes WHERE voter_id = @voterId";
                using (var checkCmd = new NpgsqlCommand(checkSql, _pgConnection))
                {
                    checkCmd.Parameters.AddWithValue("voterId", voteData.VoterId);
                    var count = (long)await checkCmd.ExecuteScalarAsync(cancellationToken);
                    
                    if (count > 0)
                    {
                        _logger.LogInformation($"Duplicate vote from {voteData.VoterId}, ignoring");
                        return;
                    }
                }

                // Insert vote
                var insertSql = "INSERT INTO votes (voter_id, vote) VALUES (@voterId, @vote)";
                using (var insertCmd = new NpgsqlCommand(insertSql, _pgConnection))
                {
                    insertCmd.Parameters.AddWithValue("voterId", voteData.VoterId);
                    insertCmd.Parameters.AddWithValue("vote", voteData.Vote);
                    await insertCmd.ExecuteNonQueryAsync(cancellationToken);
                }

                _logger.LogInformation($"Processed vote: {voteData.Vote} from {voteData.VoterId}");
            }
            catch (JsonException ex)
            {
                _logger.LogError(ex, "Failed to deserialize vote data");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error processing vote");
                throw; // Re-throw to trigger retry logic
            }
        }

        private async Task ReconnectRedisAsync(CancellationToken cancellationToken)
        {
            try
            {
                _redis?.Close();
                _redis?.Dispose();
                
                var redisHost = _configuration["REDIS_HOST"] ?? "redis";
                var redisPort = int.Parse(_configuration["REDIS_PORT"] ?? "6379");
                _redis = await ConnectionMultiplexer.ConnectAsync($"{redisHost}:{redisPort}");
                _db = _redis.GetDatabase();
                _logger.LogInformation("Reconnected to Redis");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to reconnect to Redis");
                await Task.Delay(10000, cancellationToken);
            }
        }

        private async Task ReconnectPostgresAsync(CancellationToken cancellationToken)
        {
            try
            {
                _pgConnection?.Close();
                _pgConnection?.Dispose();
                
                var dbHost = _configuration["DB_HOST"] ?? "db";
                var dbPort = _configuration["DB_PORT"] ?? "5432";
                var dbName = _configuration["DB_NAME"] ?? "postgres";
                var dbUser = _configuration["DB_USER"] ?? "postgres";
                var dbPasswordFile = _configuration["DB_PASSWORD_FILE"] ?? "/run/secrets/db_password";
                var dbPassword = File.Exists(dbPasswordFile) 
                    ? File.ReadAllText(dbPasswordFile).Trim() 
                    : _configuration["DB_PASSWORD"] ?? "";

                var pgConnectionString = $"Host={dbHost};Port={dbPort};Database={dbName};Username={dbUser};Password={dbPassword};";
                _pgConnection = new NpgsqlConnection(pgConnectionString);
                await _pgConnection.OpenAsync(cancellationToken);
                _logger.LogInformation("Reconnected to PostgreSQL");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to reconnect to PostgreSQL");
                await Task.Delay(10000, cancellationToken);
            }
        }

        public override async Task StopAsync(CancellationToken cancellationToken)
        {
            _logger.LogInformation("Stopping Vote Processor...");
            
            _redis?.Close();
            _redis?.Dispose();
            
            _pgConnection?.Close();
            _pgConnection?.Dispose();
            
            await base.StopAsync(cancellationToken);
        }
    }

    public class VoteData
    {
        public string VoterId { get; set; }
        public string Vote { get; set; }
    }
}