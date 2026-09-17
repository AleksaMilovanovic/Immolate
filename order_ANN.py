file = open('ANN_output.txt', 'r', encoding='utf-16', errors='replace')
print("Top 20 seeds with highest values:")

seeds = []
for line in file:
    line = line.strip()
    if line[-1] != ')':
        continue
    tokens = line.split(' ')
    if len(tokens) != 2:
        continue

    seed = tokens[0]
    value = int(tokens[1][1:-1])
    #if value > 3600:
    seeds.append((seed, value))
        #seeds.append(seed)
  
seeds.sort(key=lambda x: x[1], reverse=True)
for seed in seeds[:20]:
  print(seed)