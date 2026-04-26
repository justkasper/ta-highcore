"""Render dashboard sketch chart mockups as PNGs.

Outputs to docs/img/dashboard/. One file per block (4.1..4.5) of
docs/dashboard_sketch.md. All numbers are real, queried from the
current build of mart_retention_* / mart_revenue_* via DuckDB
(read-only). The public sample is small (50k events/day cap) so
absolute revenue/retention numbers are below typical-F2P scale —
reflect that, don't fabricate.
"""

from pathlib import Path

import duckdb
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "warehouse.duckdb"
OUT = ROOT / "docs" / "img" / "dashboard"
OUT.mkdir(parents=True, exist_ok=True)

DAY_AXIS = [0, 1, 3, 7, 14, 30]
LAST_FULL_COHORT = "2018-09-04"
TRIANGLE_COHORTS = ("2018-09-23", "2018-09-27")
COHORT_COMPARISON = ["2018-09-06", "2018-09-12", "2018-09-19", "2018-09-24"]


def q(sql: str) -> pd.DataFrame:
    con = duckdb.connect(str(DB), read_only=True)
    try:
        return con.execute(sql).fetchdf()
    finally:
        con.close()


def style():
    plt.rcParams.update(
        {
            "figure.figsize": (8, 4.5),
            "figure.dpi": 130,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.grid": True,
            "grid.alpha": 0.25,
            "grid.linestyle": "--",
            "font.size": 11,
            "axes.titlesize": 13,
            "axes.titleweight": "bold",
            "legend.frameon": False,
        }
    )


def save(fig, name):
    path = OUT / f"{name}.png"
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {path.relative_to(ROOT)}")


def _delta_color(diff, threshold):
    if pd.isna(diff) or abs(diff) < threshold:
        return "#888888"
    return "#2b6cb0" if diff > 0 else "#e53e3e"


def header_kpis():
    """Block 4.1 — KPI tiles for last fully observed cohort."""
    ret = q(
        f"""
        select day_number, retention_pct,
               retention_pct_trailing_4w_avg::double as baseline
        from mart_retention_overall
        where cohort_date = '{LAST_FULL_COHORT}'
          and day_number in (1, 3, 7)
        order by day_number
        """
    ).set_index("day_number")
    rev = q(
        f"""
        select cum_arpu::double as cum_arpu,
               cum_arpu_trailing_4w_avg::double as cum_arpu_baseline,
               paying_share::double as paying_share
        from mart_revenue_overall
        where cohort_date = '{LAST_FULL_COHORT}' and day_number = 7
        """
    ).iloc[0]
    paying_baseline = q(
        f"""
        select avg(paying_share)::double as v
        from mart_revenue_overall
        where day_number = 7
          and cohort_date < '{LAST_FULL_COHORT}'
          and cohort_date >= (date '{LAST_FULL_COHORT}' - interval 28 day)
        """
    ).iloc[0]["v"]

    def _pp(diff):
        if pd.isna(diff):
            return "no baseline"
        return f"{diff*100:+.1f}pp vs 4w"

    def _money(diff):
        if pd.isna(diff):
            return "no baseline"
        return f"{diff:+.4f} vs 4w"

    arpu_d = float(rev["cum_arpu"]) - float(rev["cum_arpu_baseline"])
    pay_d = float(rev["paying_share"]) - float(paying_baseline) if not pd.isna(paying_baseline) else float("nan")
    d1_d = float(ret.loc[1, "retention_pct"]) - float(ret.loc[1, "baseline"])
    d3_d = float(ret.loc[3, "retention_pct"]) - float(ret.loc[3, "baseline"])
    d7_d = float(ret.loc[7, "retention_pct"]) - float(ret.loc[7, "baseline"])

    kpis = [
        ("ARPU @ D7", f"${float(rev['cum_arpu']):.4f}", _money(arpu_d), _delta_color(arpu_d, 0.0005)),
        ("Pay share @ D7", f"{float(rev['paying_share'])*100:.2f}%", _pp(pay_d), _delta_color(pay_d, 0.001)),
        ("D1 retention", f"{float(ret.loc[1, 'retention_pct'])*100:.1f}%", _pp(d1_d), _delta_color(d1_d, 0.005)),
        ("D3 retention", f"{float(ret.loc[3, 'retention_pct'])*100:.1f}%", _pp(d3_d), _delta_color(d3_d, 0.005)),
        ("D7 retention", f"{float(ret.loc[7, 'retention_pct'])*100:.1f}%", _pp(d7_d), _delta_color(d7_d, 0.005)),
    ]

    fig, ax = plt.subplots(figsize=(11, 3.2))
    ax.axis("off")
    n = len(kpis)
    for i, (title, value, delta, colour) in enumerate(kpis):
        x0 = i / n
        w = 1 / n - 0.02
        ax.add_patch(
            plt.Rectangle(
                (x0, 0.0), w, 1.0, transform=ax.transAxes,
                fill=True, facecolor="#f7fafc", edgecolor="#cbd5e0", linewidth=1.2,
            )
        )
        ax.text(x0 + w / 2, 0.78, title, ha="center", va="center",
                transform=ax.transAxes, fontsize=11, color="#4a5568")
        ax.text(x0 + w / 2, 0.45, value, ha="center", va="center",
                transform=ax.transAxes, fontsize=22, fontweight="bold", color="#1a202c")
        ax.text(x0 + w / 2, 0.15, delta, ha="center", va="center",
                transform=ax.transAxes, fontsize=10, color=colour)
    ax.set_title(f"Block 4.1 — Header KPIs (selected cohort {LAST_FULL_COHORT}, real)")
    save(fig, "01_header_kpis")


def cohort_triangle_real():
    """Block 4.2 — last cohorts with at least D7 follow-up; latest on top."""
    start, end = TRIANGLE_COHORTS
    df = q(
        f"""
        select cohort_date, cohort_size, day_number, retention_pct
        from mart_retention_overall
        where cohort_date between '{start}' and '{end}'
          and day_number in (0, 1, 3, 7, 14, 30)
        order by cohort_date desc, day_number
        """
    )
    cohorts = sorted(df["cohort_date"].unique(), reverse=True)
    sizes = (
        df[df["day_number"] == 0].set_index("cohort_date")["cohort_size"].astype(int).to_dict()
    )
    pivot = df.pivot(index="cohort_date", columns="day_number", values="retention_pct")
    pivot = pivot.loc[cohorts, DAY_AXIS]
    pct = pivot.values * 100.0  # → percentage

    fig, ax = plt.subplots(figsize=(9, 4.2))
    masked = np.ma.masked_invalid(pct)
    im = ax.imshow(masked, cmap="YlGnBu", aspect="auto", vmin=0, vmax=25)
    ax.set_xticks(range(len(DAY_AXIS)), [f"D{d}" for d in DAY_AXIS])
    ax.set_yticks(
        range(len(cohorts)),
        [f"{str(c)[:10]}\n(n={sizes.get(c, 0)})" for c in cohorts],
    )
    ax.set_xlabel("day_number")
    ax.set_title("Block 4.2 — Cohort retention triangle (real, latest on top)")
    for i in range(pct.shape[0]):
        for j in range(pct.shape[1]):
            v = pct[i, j]
            if np.isnan(v):
                ax.text(j, i, "—", ha="center", va="center", color="#999", fontsize=10)
                continue
            color = "white" if v > 15 else "black"
            ax.text(j, i, f"{v:.1f}", ha="center", va="center", color=color, fontsize=10)
    cbar = fig.colorbar(im, ax=ax, shrink=0.85)
    cbar.set_label("retention_pct (%) — capped at 25 for colour scale")
    fig.text(
        0.5, -0.02,
        "Note: D0 = 100% by construction. Cohort sizes reflect 50k events/day public sample. D14/D30 partially right-censored for the latest 2 cohorts.",
        ha="center", fontsize=9, style="italic",
    )
    save(fig, "02_cohort_triangle")


def current_vs_baseline():
    """Block 4.3 — 2-panel: retention | cum_arpu, both selected vs trailing 4w."""
    ret = q(
        f"""
        select day_number,
               retention_pct::double as selected,
               retention_pct_trailing_4w_avg::double as baseline
        from mart_retention_overall
        where cohort_date = '{LAST_FULL_COHORT}'
          and day_number in (0, 1, 3, 7, 14, 30)
        order by day_number
        """
    )
    rev = q(
        f"""
        select day_number,
               cum_arpu::double as selected,
               cum_arpu_trailing_4w_avg::double as baseline
        from mart_revenue_overall
        where cohort_date = '{LAST_FULL_COHORT}'
          and day_number in (0, 1, 3, 7, 14, 30)
        order by day_number
        """
    )

    fig, axes = plt.subplots(1, 2, figsize=(15, 4.6))

    ax = axes[0]
    days = ret["day_number"].tolist()
    sel = (ret["selected"] * 100).tolist()
    base = (ret["baseline"] * 100).tolist()
    ax.plot(days, base, "o-", color="#888", lw=2.2, label="trailing 4w avg")
    ax.plot(days, sel, "o-", color="#2b6cb0", lw=2.5, label=f"selected ({LAST_FULL_COHORT})")
    base_arr = np.array(base, dtype=float)
    sel_arr = np.array(sel, dtype=float)
    ax.fill_between(days, sel_arr, base_arr, where=base_arr > sel_arr,
                    color="#e53e3e", alpha=0.12, label="underperformance")
    ax.set_xlabel("day_number")
    ax.set_ylabel("retention_pct (%)")
    ax.set_title("retention — selected vs trailing 4w")
    ax.set_xticks(days)
    ax.legend(loc="upper right")

    ax = axes[1]
    days = rev["day_number"].tolist()
    sel = rev["selected"].tolist()
    base = rev["baseline"].tolist()
    ax.plot(days, base, "o-", color="#888", lw=2.2, label="trailing 4w avg")
    ax.plot(days, sel, "o-", color="#dd6b20", lw=2.5, label=f"selected ({LAST_FULL_COHORT})")
    base_arr = np.array(base, dtype=float)
    sel_arr = np.array(sel, dtype=float)
    ax.fill_between(days, sel_arr, base_arr, where=base_arr > sel_arr,
                    color="#e53e3e", alpha=0.12, label="underperformance")
    ax.set_xlabel("day_number")
    ax.set_ylabel("cum_arpu (USD)")
    ax.set_title("cum_arpu — selected vs trailing 4w")
    ax.set_xticks(days)
    ax.legend(loc="upper left")

    fig.suptitle(f"Block 4.3 — Current cohort {LAST_FULL_COHORT} vs trailing 4w (real)", fontweight="bold")
    save(fig, "03_current_vs_baseline")


def cohort_comparison():
    """Block 4.4 — 3-panel cohort comparison: D7 trend, cum_arpu, paying_share.

    Panel order matches Block 4.5 (retention → arpu → paying_share).
    D7 trend uses weekly rollup (cohort-size-weighted) — same approach
    as 4.5 — so both blocks read identically left to right.
    """
    cohorts_sql = "', '".join(COHORT_COMPARISON)
    arpu = q(
        f"""
        select cohort_date, day_number, cum_arpu::double as cum_arpu, paying_share::double as paying_share
        from mart_revenue_overall
        where cohort_date in ('{cohorts_sql}')
          and day_number in (0, 1, 3, 7, 14, 30)
        order by cohort_date, day_number
        """
    )
    d7 = q(
        """
        select date_trunc('week', cohort_date) as week,
               sum(retained_users)::double / nullif(sum(cohort_size), 0) as ret
        from mart_retention_overall
        where day_number = 7
          and cohort_date >= '2018-07-01'
          and cohort_date <= '2018-09-27'
        group by 1
        order by 1
        """
    )

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.6))
    cmap = plt.get_cmap("viridis")

    ax = axes[0]
    ax.plot(d7["week"], d7["ret"] * 100, "o-", color="#2b6cb0", lw=2.2, ms=5)
    ax.set_xlabel("cohort_date (weekly)")
    ax.set_ylabel("retention_pct @ D7 (%)")
    ax.set_title("D7 retention trend across cohorts (weighted)")
    ax.tick_params(axis="x", rotation=30, labelsize=8)

    ax = axes[1]
    for i, c in enumerate(COHORT_COMPARISON):
        sub = arpu[arpu["cohort_date"].astype(str) == c]
        ax.plot(sub["day_number"], sub["cum_arpu"], "o-",
                color=cmap(0.15 + i * 0.22), lw=2.0, label=c)
    ax.set_xlabel("day_number")
    ax.set_ylabel("cum_arpu (USD)")
    ax.set_title("cum_arpu by cohort")
    ax.set_xticks(DAY_AXIS)
    ax.legend(title="cohort_date", loc="upper left", fontsize=9)

    ax = axes[2]
    for i, c in enumerate(COHORT_COMPARISON):
        sub = arpu[arpu["cohort_date"].astype(str) == c]
        ax.plot(sub["day_number"], sub["paying_share"] * 100, "o-",
                color=cmap(0.15 + i * 0.22), lw=2.0, label=c)
    ax.set_xlabel("day_number")
    ax.set_ylabel("paying_share (%)")
    ax.set_title("paying_share by cohort")
    ax.set_xticks(DAY_AXIS)
    ax.legend(title="cohort_date", loc="upper left", fontsize=9)

    fig.suptitle("Block 4.4 — Cohort comparison (real, D7 trend weekly)", fontweight="bold")
    save(fig, "04_cohort_comparison")


def platform_breakdown():
    """Block 4.5 — 3-panel iOS vs Android breakdown.

    D7 trend uses weekly rollup (mean of cohort_date in the week).
    cum_arpu / paying_share aggregated as cohort-size-weighted mean across
    the period to avoid noise from small daily cohorts.
    """
    d7 = q(
        """
        select date_trunc('week', cohort_date) as week,
               install_platform,
               sum(retained_users)::double / nullif(sum(cohort_size), 0) as ret
        from mart_retention_by_platform
        where day_number = 7
          and cohort_date >= '2018-07-01'
          and cohort_date <= '2018-09-27'
        group by 1, 2
        order by 1, 2
        """
    )
    revenue = q(
        """
        select install_platform, day_number,
               sum(cum_revenue)::double / nullif(sum(cohort_size), 0) as cum_arpu_w,
               sum(cum_paying_users)::double / nullif(sum(cohort_size), 0) as paying_share_w
        from mart_revenue_by_platform
        where day_number in (0, 1, 3, 7, 14, 30)
          and cohort_date >= '2018-07-01'
          and cohort_date <= '2018-09-27'
        group by 1, 2
        order by 1, 2
        """
    )

    plat_colors = {"ANDROID": "#3ddc84", "IOS": "#007aff"}

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.6))

    ax = axes[0]
    for plat, col in plat_colors.items():
        sub = d7[d7["install_platform"] == plat]
        ax.plot(sub["week"], sub["ret"] * 100, "o-", color=col, lw=2.2, label=plat, ms=5)
    ax.set_ylabel("retention_pct @ D7 (%)")
    ax.set_xlabel("cohort_date (weekly)")
    ax.set_title("D7 retention by platform (weighted)")
    ax.tick_params(axis="x", rotation=30, labelsize=8)
    ax.legend(loc="upper right")

    ax = axes[1]
    for plat, col in plat_colors.items():
        sub = revenue[revenue["install_platform"] == plat]
        ax.plot(sub["day_number"], sub["cum_arpu_w"], "o-", color=col, lw=2.2, label=plat)
    ax.set_xlabel("day_number")
    ax.set_ylabel("cum_arpu (USD, period-weighted)")
    ax.set_title("cum_arpu by platform")
    ax.set_xticks(DAY_AXIS)
    ax.legend(loc="upper left")

    ax = axes[2]
    for plat, col in plat_colors.items():
        sub = revenue[revenue["install_platform"] == plat]
        ax.plot(sub["day_number"], sub["paying_share_w"] * 100, "o-",
                color=col, lw=2.2, label=plat)
    ax.set_xlabel("day_number")
    ax.set_ylabel("paying_share (%, period-weighted)")
    ax.set_title("paying_share by platform")
    ax.set_xticks(DAY_AXIS)
    ax.legend(loc="upper left")

    fig.suptitle("Block 4.5 — Platform breakdown (real, weighted across 2018-07-01..2018-09-27)", fontweight="bold")
    save(fig, "05_platform_breakdown")


if __name__ == "__main__":
    style()
    header_kpis()
    cohort_triangle_real()
    current_vs_baseline()
    cohort_comparison()
    platform_breakdown()
    print("done")
