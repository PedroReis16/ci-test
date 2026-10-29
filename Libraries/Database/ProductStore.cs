using Models;

namespace Database;

public class ProductStore
{
    private readonly List<Product> _products =
    [
        new() { Id = 1, Name = "Notebook", Price = 3500m },
        new() { Id = 2, Name = "Mouse", Price = 89.90m },
        new() { Id = 3, Name = "Teclado", Price = 199.90m }
    ];

    public IReadOnlyList<Product> GetAll() => _products;

    public Product? GetById(int id) => _products.FirstOrDefault(p => p.Id == id);

    public Product Add(Product product)
    {
        product.Id = _products.Count == 0 ? 1 : _products.Max(p => p.Id) + 1;
        _products.Add(product);
        return product;
    }
}
