USE csv_test;

-- 删除旧表
DROP TABLE IF EXISTS roi_compare;

-- 1. 营销参数设置（预算、优惠券成本、客单价、转化率提升等）
SET @budget = 10000;          -- 总营销预算
SET @cost = 10;               -- 单张优惠券成本
SET @aov = (SELECT IFNULL(AVG(Average_Order_Value), 200) FROM user_personalized_features);  -- 平均订单金额

SET @crate0 = 0.25;            -- 核心用户自然转化率
SET @crate1 = 0.30;            -- 核心用户优惠券转化率
SET @clift = @crate1 - @crate0; -- 核心转化率提升

SET @prate0 = 0.01;            -- 潜力用户自然转化率
SET @prate1 = 0.20;            -- 潜力用户优惠券转化率
SET @plift = @prate1 - @prate0; -- 潜力转化率提升

SET @rrate0 = 0.20;            -- RFM前20%自然转化率
SET @rrate1 = 0.30;            -- RFM前20%优惠券转化率
SET @rlift = @rrate1 - @rrate0; -- RFM转化率提升

-- 2. 计算RFM前20%阈值
DROP TEMPORARY TABLE IF EXISTS temp_rfm_rank;
CREATE TEMPORARY TABLE temp_rfm_rank AS
SELECT
    RFM_Score,
    ROW_NUMBER() OVER (ORDER BY RFM_Score DESC) AS rn,
    COUNT(*) OVER () AS total
FROM user_segment_result;

SET @rfmline = (
    SELECT RFM_Score
    FROM temp_rfm_rank
    WHERE rn <= CEIL(total * 0.2)
    ORDER BY rn DESC
    LIMIT 1
);

-- 3. 方案A：传统RFM策略
DROP TEMPORARY TABLE IF EXISTS roia;
CREATE TEMPORARY TABLE roia AS
SELECT
    '传统RFM' AS plan,        -- 营销策略名称
    COUNT(*) AS cnt,          -- 符合条件用户数
    LEAST(COUNT(*), @budget / @cost) AS send,  -- 实际发放人数
    LEAST(COUNT(*), @budget / @cost) * @cost AS cost,  -- 总成本
    LEAST(COUNT(*), @budget / @cost) * @rlift * @aov AS income,  -- 增量收益
    ROUND(
        ((LEAST(COUNT(*), @budget / @cost) * @rlift * @aov) - (LEAST(COUNT(*), @budget / @cost) * @cost))
        / NULLIF(LEAST(COUNT(*), @budget / @cost) * @cost, 0) * 100, 2
    ) AS roi  -- 投资回报率%
FROM user_segment_result
WHERE RFM_Score >= @rfmline;

-- 4. 方案B：优化RFI策略
DROP TEMPORARY TABLE IF EXISTS roib;
CREATE TEMPORARY TABLE roib AS
SELECT
    '优化RFI' AS plan,        -- 营销策略名称

    -- 核心用户
    SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END) AS corecnt,
    LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8 / @cost) AS coresend,

    -- 潜力用户
    SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END) AS potcnt,
    LEAST(
        SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
        (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
    ) AS potsend,

    -- 总发放人数
    (
        LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost)
        + LEAST(
            SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
            (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
        )
    ) AS send,

    -- 总成本
    (
        LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost)
        + LEAST(
            SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
            (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
        )
    ) * @cost AS cost,

    -- 总收益
    (
        LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @clift * @aov
        + LEAST(
            SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
            (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
        ) * @plift * @aov
    ) AS income,

    -- 最终ROI
    ROUND(
        (
            (
                LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @clift * @aov
                + LEAST(
                    SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
                    (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
                ) * @plift * @aov
            )
            -
            (
                LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost)
                + LEAST(
                    SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
                    (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
                )
            ) * @cost
        ) / NULLIF(
            (
                LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost)
                + LEAST(
                    SUM(CASE WHEN User_Segment IN ('纠结土豪','高潜沉睡用户','犹豫型潜力用户','高潜流失客') THEN 1 ELSE 0 END),
                    (@budget - (LEAST(SUM(CASE WHEN User_Segment IN ('核心VIP','重要价值用户') THEN 1 ELSE 0 END), @budget*0.8/@cost) * @cost)) / @cost
                )
            ) * @cost, 0
        ) * 100, 2
    ) AS roi

FROM user_segment_result;

-- 5. 生成最终ROI表
CREATE TABLE roi_compare AS
SELECT plan, send, cost, income, roi FROM roia
UNION ALL
SELECT plan, send, cost, income, roi FROM roib;