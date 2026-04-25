
DROP TABLE IF EXISTS segment_stats;
CREATE TABLE segment_stats AS

SELECT
    User_Segment,
    COUNT(User_ID) AS user_count,
    ROUND(AVG(Total_Spending), 2) AS avg_spending,
    ROUND(AVG(Purchase_Frequency), 2) AS avg_freq,
    ROUND(AVG(I_Score), 2) AS avg_iscore,
    ROUND(AVG(Income), 2) AS avg_income,
    ROUND(AVG(Final_Score), 2) AS avg_final_score,
    ROUND(COUNT(User_ID) / (SELECT COUNT(*) FROM user_segment_result) * 100, 1) AS percentage
FROM user_segment_result
GROUP BY User_Segment
ORDER BY user_count DESC;
