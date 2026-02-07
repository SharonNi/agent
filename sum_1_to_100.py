#!/usr/bin/env python3
"""
计算1到100的连加和

该脚本演示了两种方法来计算1到100的总和：
1. 使用Python的sum()函数和range()函数
2. 使用数学公式 n(n+1)/2 进行验证
"""

def calculate_sum(start=1, end=100):
    """
    计算从start到end的连加和
    
    该函数使用Python内置的sum()函数计算指定范围内所有整数的总和。

    参数:
        start (int): 起始数字，默认为1
        end (int): 结束数字，默认为100

    返回:
        int: 从start到end的总和
    
    示例:
        >>> calculate_sum(1, 100)
        5050
        >>> calculate_sum(1, 10)
        55
    """
    # 使用sum()函数直接计算范围内的总和
    # range(start, end+1)生成从start到end的数字序列
    total = sum(range(start, end + 1))
    return total


if __name__ == "__main__":
    # 调用函数计算1到100的总和
    result = calculate_sum(1, 100)
    print(f"1到100的连加和为: {result}")

    # 验证结果（使用数学公式：n(n+1)/2）
    # 该公式是高斯求和公式，用于快速计算连续整数的总和
    n = 100
    formula_result = n * (n + 1) // 2  # 使用整数除法确保结果为整数
    print(f"使用公式验证: {formula_result}")
