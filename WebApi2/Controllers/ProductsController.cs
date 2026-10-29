using Database;
using Microsoft.AspNetCore.Mvc;
using Models;

namespace WebApi2.Controllers;

[ApiController]
[Route("api/[controller]")]
public class ProductsController(ProductStore store) : ControllerBase
{
    [HttpGet]
    public ActionResult<IEnumerable<Product>> GetAll() => Ok(store.GetAll());

    [HttpGet("{id:int}")]
    public ActionResult<Product> GetById(int id)
    {
        var product = store.GetById(id);
        return product is null ? NotFound() : Ok(product);
    }

    [HttpPost]
    public ActionResult<Product> Create(Product product)
    {
        var created = store.Add(product);
        return CreatedAtAction(nameof(GetById), new { id = created.Id }, created);
    }
}
