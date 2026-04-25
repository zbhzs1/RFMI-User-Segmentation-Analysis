USE csv_test;

-- ==============================================
-- 第一步：完整用户分群逻辑，结果存入永久实体表 user_segment_result
-- ==============================================
DROP TABLE IF EXISTS user_segment_result;
CREATE TABLE user_segment_result AS
WITH 
-- 1. 全局最值：用于 Min-Max 归一化
global_stats AS (
    SELECT
        MIN(Time_Spent_on_Site_Minutes) AS min_time,
        MAX(Time_Spent_on_Site_Minutes) AS max_time,
        MIN(Pages_Viewed) AS min_pages,
        MAX(Pages_Viewed) AS max_pages,

        MIN(Last_Login_Days_Ago) AS R_min,
        MAX(Last_Login_Days_Ago) AS R_max,
        MIN(Purchase_Frequency) AS F_min,
        MAX(Purchase_Frequency) AS F_max,
        MIN(Total_Spending) AS M_min,
        MAX(Total_Spending) AS M_max,

        MIN(Income) AS min_income,
        MAX(Income) AS max_income
    FROM user_personalized_features
),

-- 2. 收入分位数 33% / 66%
income_quant AS (
    SELECT
        MAX(IF(rn <= total * 0.33, Income, NULL)) AS q33,
        MAX(IF(rn <= total * 0.66, Income, NULL)) AS q66
    FROM (
        SELECT
            Income,
            ROW_NUMBER() OVER (ORDER BY Income) AS rn,
            COUNT(*) OVER () AS total
        FROM user_personalized_features
    ) t
),

-- 3. 特征工程
feature_eng AS (
    SELECT
        u.*,
        (
            CASE WHEN g.max_time = g.min_time THEN 50
                 ELSE (u.Time_Spent_on_Site_Minutes - g.min_time) / (g.max_time - g.min_time) * 100 END
            +
            CASE WHEN g.max_pages = g.min_pages THEN 50
                 ELSE (u.Pages_Viewed - g.min_pages) / (g.max_pages - g.min_pages) * 100 END
        ) / 2 AS I_Score,

        u.Pages_Viewed / (u.Purchase_Frequency + 1) AS Friction,

        CASE
            WHEN u.Newsletter_Subscription = 'True' AND u.Last_Login_Days_Ago <= 7 THEN 3
            WHEN u.Newsletter_Subscription = 'False' AND u.Last_Login_Days_Ago <= 7 THEN 2
            ELSE 1
        END AS L_Score,

        CASE
            WHEN u.Income < i.q33 THEN 'Low'
            WHEN u.Income < i.q66 THEN 'Medium'
            ELSE 'High'
        END AS Income_Level

    FROM user_personalized_features u
    CROSS JOIN global_stats g
    CROSS JOIN income_quant i
),

-- 4. RFM 得分
rfm_score AS (
    SELECT
        fe.*,
        CASE WHEN g.R_max = g.R_min THEN 50
             ELSE (g.R_max - fe.Last_Login_Days_Ago) / (g.R_max - g.R_min) * 100 END AS R_Score,
        CASE WHEN g.F_max = g.F_min THEN 50
             ELSE (fe.Purchase_Frequency - g.F_min) / (g.F_max - g.F_min) * 100 END AS F_Score,
        CASE WHEN g.M_max = g.M_min THEN 50
             ELSE (fe.Total_Spending - g.M_min) / (g.M_max - g.M_min) * 100 END AS M_Score
    FROM feature_eng fe
    CROSS JOIN global_stats g
),

-- 5. 最终得分
final_calc AS (
    SELECT
        *,
        0.2 * R_Score + 0.3 * F_Score + 0.5 * M_Score AS RFM_Score,
        I_Score / 500 AS I_Weight,
        (0.2 * R_Score + 0.3 * F_Score + 0.5 * M_Score) * (1 + I_Score / 500) AS Final_Score
    FROM rfm_score
),

-- 6. 摩擦 60% 分位数（MySQL原生兼容版）
friction_params AS (
    SELECT
        MAX(IF(row_num <= total * 0.6, Friction, NULL)) AS friction_threshold
    FROM (
        SELECT
            Friction,
            ROW_NUMBER() OVER (ORDER BY Friction) AS row_num,
            COUNT(*) OVER () AS total
        FROM final_calc
    ) AS temp
),

-- 7. 用户分层规则（完全复刻原版）
user_segmentation AS (
    SELECT
        t2.*,
        CASE
            WHEN M_Score > 70 AND F_Score > 70 AND I_Score > 60 THEN '核心VIP'
            WHEN Income_Level = 'High' AND I_Score > 70 AND F_Score < 40 AND M_Score < 50 THEN '纠结土豪'
            WHEN Income_Level = 'High' AND R_Score < 40 AND M_Score > 50 THEN '高潜流失客'
            WHEN (base_label IN ('低价值用户','一般维持用户')) AND Income_Level = 'High' AND I_Score > 60 THEN '高潜沉睡用户'
            WHEN (base_label IN ('一般维持用户','一般发展用户')) AND I_Score > 80 AND Friction > fp.friction_threshold THEN '犹豫型潜力用户'
            WHEN Income_Level = 'Low' AND I_Score > 70 AND F_Score < 40 THEN '隐形活跃者'
            WHEN Income_Level = 'Low' AND I_Score < 40 AND M_Score < 40 THEN '羊毛党/低值'
            ELSE base_label
        END AS User_Segment
    FROM (
        SELECT
            *,
            CASE
                WHEN R_Score > 60 AND F_Score > 60 AND M_Score > 60 THEN '重要价值用户'
                WHEN R_Score > 60 AND M_Score > 60 AND F_Score < 40 THEN '重要发展用户'
                WHEN R_Score < 40 AND F_Score > 60 AND M_Score > 60 THEN '重要保持用户'
                WHEN R_Score < 40 AND M_Score > 60 THEN '重要挽留用户'
                WHEN R_Score > 60 AND F_Score > 40 AND M_Score < 40 THEN '一般发展用户'
                WHEN R_Score > 60 AND F_Score < 40 AND M_Score < 40 THEN '一般维持用户'
                WHEN R_Score < 40 AND F_Score < 40 AND M_Score < 40 THEN '低价值用户'
                ELSE '一般用户'
            END AS base_label
        FROM final_calc
    ) t2
    CROSS JOIN friction_params fp
)
SELECT * FROM user_segmentation;