# Year-to-Year
set terminal dumb 80 25
set title "Year-to-Year Partition Growth"
set xlabel "Year"
set ylabel "Growth"
set style data linespoints
plot "-" using 1:2 title "Partitions"
2023 49
2024 715
2025 1009
2026 57
e

# Quarterly
set title "Quarterly Partition Growth (2024-2025)"
set xlabel "Quarter Index"
set xtics ("24Q1" 1, "24Q2" 2, "24Q3" 3, "24Q4" 4, "25Q1" 5, "25Q2" 6, "25Q3" 7, "25Q4" 8)
plot "-" using 1:2 title "Partitions"
1 0
2 69
3 321
4 325
5 345
6 265
7 266
8 133
e

# Weekly Peak Feb 2025
set title "Weekly Growth - Feb 2025 Peak"
set xlabel "Week"
set xtics ("W1" 1, "W2" 2, "W3" 3, "W4" 4)
plot "-" using 1:2 title "Partitions"
1 53
2 26
3 24
4 24
e

# Weekly Peak July 2025
set title "Weekly Growth - July 2025 Peak"
set xlabel "Week"
set xtics ("W1" 1, "W2" 2, "W3" 3, "W4" 4, "W5" 5)
plot "-" using 1:2 title "Partitions"
1 50
2 30
3 19
4 15
5 8
e
