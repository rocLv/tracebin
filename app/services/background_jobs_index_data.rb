class BackgroundJobsIndexData
  def initialize(app_bin_id)
    @app_bin_id = app_bin_id
  end

  def fetch!
    tuples = fetch_tuples
    process_tuples tuples
  end

  private

  def fetch_tuples
    sql = <<~SQL
      SELECT
        name AS job_name,
        quantile(duration, 0.5) AS median_duration,
        quantile(duration, 0.95) AS ninety_fith_percentile_duration,
        count(*) AS hits,
        avg((
          SELECT sum(duration)
          FROM jsonb_to_recordset(events->'sql') AS x(duration NUMERIC)
        )) AS avg_time_in_sql,
        avg((
          -- View events happen within each other, so we just need to take the
          -- highest value here.
          SELECT max(duration) - (
            SELECT sum(duration)
            FROM
              jsonb_to_recordset(events->'sql')
                AS y(duration NUMERIC, start TIMESTAMP, stop TIMESTAMP)
            WHERE
              y.start >= min(x.start) AND y.stop <= max(x.stop)
          )
          FROM
            jsonb_to_recordset(events->'view')
              AS x(duration NUMERIC, start TIMESTAMP, stop TIMESTAMP)
        )) AS avg_time_in_view,
        avg(duration) AS avg_time_in_app,
        avg((
          SELECT sum(duration)
          FROM jsonb_to_recordset(events->'other') AS x(duration NUMERIC)
        )) AS avg_time_in_other,
        max(events::TEXT)
      FROM cycle_transactions
      WHERE
        app_bin_id = #{ActiveRecord::Base.sanitize @app_bin_id} AND
        transaction_type = 'background_job' AND
        start > (current_timestamp - interval '1 day')
      GROUP BY job_name
      ORDER BY hits DESC;
    SQL

    ActiveRecord::Base.connection.execute sql
  end

  def process_tuples(tuples)
    tuples.to_a.map do |tuple|
      total_time = tuple['avg_time_in_app'].to_f.round(4)
      sql_time = tuple['avg_time_in_sql'].to_f.round(4)
      view_time = tuple['avg_time_in_view'].to_f.round(4)
      other_time = tuple['avg_time_in_other'].to_f.round(4)

      app_percent = (((total_time - sql_time - view_time - other_time) / total_time) * 100).round 2
      sql_percent = (sql_time / total_time * 100).round 2
      view_percent = (view_time / total_time * 100).round 2
      other_percent = (other_time / total_time * 100).round 2

      [
        tuple['job_name'],
        tuple['hits'],
        tuple['median_duration'].to_f.round(2),
        tuple['ninety_fith_percentile_duration'].to_f.round(2),
        app_percent,
        sql_percent,
        view_percent,
        other_percent
      ]
    end
  end
end
