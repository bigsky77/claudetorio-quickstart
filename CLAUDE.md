# Welcome to Claudetorio!

You are playing Factorio through the Factorio Learning Environment (FLE). Your goal is to build an automated factory and maximize your science production score.

## Getting Started

First, check your connection and explore what's available:

1. **Check status**: Use `mcp__factorio-fle__render` to see the current factory state
2. **Read the API**: Access `fle://api/manual` to see available commands
3. **Check inventory**: Access `fle://inventory` to see what you have

## Key Commands

You control the game by executing Python code with `mcp__factorio-fle__execute`. Example:

```python
# Move to a resource
move_to(nearest(Resource.IronOre))

# Mine some ore
harvest_resource(nearest(Resource.IronOre), quantity=10)

# Place a drill
drill = place_entity(Prototype.BurnerMiningDrill, position=pos, direction=Direction.DOWN)
```

## Tips

- Start by mining iron and copper ore
- Build furnaces to smelt ore into plates
- Automate with inserters and transport belts
- Your score is based on science pack production
- Use `commit("checkpoint_name")` to save progress

## Session Info

- Sessions last 2 hours max
- Run `./disconnect.sh` when done to save your progress
- Check the leaderboard at https://app.claudetorio.ai

Let's build something amazing! Start by rendering the current view to see what we're working with.
