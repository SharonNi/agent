#!/usr/bin/env python3
"""
计算1到100的连加和
"""

def calculate_sum(start=1, end=100):
    """
    计算从start到end的连加和

    参数:
        start: 起始数字，默认为1
        end: 结束数字，默认为100

    返回:
        总和
    """
    total = sum(range(start, end + 1))
    return total


if __name__ == "__main__":
    result = calculate_sum(1, 100)
    print(f"1到100的连加和为: {result}")

    # 验证结果（使用数学公式：n(n+1)/2）
    n = 100
    formula_result = n * (n + 1) // 2
    print(f"使用公式验证: {formula_result}")
