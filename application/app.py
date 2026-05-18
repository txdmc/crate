from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()

class Item(BaseModel):
    id: str
    name: str
    quantity: int

inventory = {}

@app.get("/")
def read_root():
    return {"message": "Inventory Tracking Application"}

@app.get("/inventory")
def get_inventory():
    return inventory

@app.post("/inventory")
def add_item(item: Item):
    inventory[item.id] = {"name": item.name, "quantity": item.quantity}
    return {"message": "Item added", "item": inventory[item.id]}

@app.delete("/inventory/{item_id}")
def delete_item(item_id: str):
    if item_id in inventory:
        del inventory[item_id]
        return {"message": "Item deleted"}
    else:
        raise HTTPException(status_code=404, detail="Item not found")