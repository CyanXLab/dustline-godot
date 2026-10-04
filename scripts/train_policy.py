#!/usr/bin/env python3
"""微操瞄准策略训练 (numpy CEM) → nn_policy.json
任务: 给定瞄准误差状态, 输出修正量, 最小化残差 (模拟 bot 的 micro-aim)
"""
import numpy as np, json

rng = np.random.default_rng(4717)
H, OBS, ACT = 24, 6, 2
POP, ELITE, ITERS, SIGMA = 96, 12, 40, 0.5

def mlp(params, obs):
    w1, b1, w2, b2 = params
    h = np.tanh(obs @ w1 + b1)
    return np.tanh(h @ w2 + b2)

def rollout(params, n=256, steps=8):
    """累计奖励: 每步残差减少量 (误差→修正收敛)"""
    total = 0.0
    for _ in range(n):
        err = rng.uniform(-1, 1, ACT) * 1.5          # 初始误差(度)
        vel = rng.uniform(-0.3, 0.3, ACT)            # 目标漂移
        for _ in range(steps):
            obs = np.concatenate([err / 1.5, [vel[0]/0.3, vel[1]/0.3, 0.9, 1.0]])[:OBS]
            corr = mlp(params, obs[None, :])[0] * 1.0
            err = err * 0.85 + vel * 0.1 - corr * 1.5  # 应用修正
            vel *= 0.98
            total += -np.abs(err).mean()
    return total / n

# 参数初始化
def sample_params(mu=None, sigma=SIGMA):
    if mu is None:
        w1 = rng.normal(0, sigma, (OBS, H)); b1 = rng.normal(0, sigma, H)
        w2 = rng.normal(0, sigma, (H, ACT)); b2 = rng.normal(0, sigma, ACT)
        return [w1, b1, w2, b2]
    return [mu[i] + rng.normal(0, sigma[i] if isinstance(sigma, list) else sigma, mu[i].shape) for i in range(4)]

best = sample_params()
mu, sd = None, SIGMA
history = []
for it in range(ITERS):
    pop = [sample_params(mu, sd) for _ in range(POP)] if mu is not None else [sample_params() for _ in range(POP)]
    fits = [rollout(p) for p in pop]
    order = np.argsort(fits)[::-1][:ELITE]
    elites = [pop[i] for i in order]
    history.append(float(np.mean(fits)))
    if it % 5 == 0:
        print(f"iter {it}: mean={np.mean(fits):.2f} best={fits[order[0]]:.2f}")
    mu = [np.mean([e[i] for e in elites], axis=0) for i in range(4)]
    sd = [max(0.02, float(np.std([e[i] for e in elites]))) for i in range(4)] if False else [0.15, 0.15, 0.15, 0.15]
    best = elites[0]

final = rollout(best, n=512)
print(f"训练完成: 最终奖励 {final:.2f} (随机策略约 {rollout(sample_params(), n=256):.2f})")

w1, b1, w2, b2 = best
policy = {
    "w1": np.round(w1, 4).tolist(), "b1": np.round(b1, 4).tolist(),
    "w2": np.round(w2, 4).tolist(), "b2": np.round(b2, 4).tolist(),
    "meta": {"obs": "yaw_err,pitch_err,vel,vel,grounded,lock", "act": "yaw_adj,pitch_adj (度×1.5)",
             "algorithm": "CEM", "iters": ITERS, "pop": POP, "final_score": round(final, 3)},
}
with open("/home/z/my-project/dustline-godot/assets/nn_policy.json", "w") as f:
    json.dump(policy, f)
print("→ assets/nn_policy.json")
