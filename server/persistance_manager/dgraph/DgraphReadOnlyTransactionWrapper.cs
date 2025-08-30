// Wrapper pour les transactions en lecture seule
using System;
using System.Threading.Tasks;
using Grpc.Core;

public class DgraphReadOnlyTransactionWrapper : IReadOnlyTransaction
{
    private readonly Dgraph.Transactions.IQuery  _dgraphTransaction;

    public DgraphReadOnlyTransactionWrapper(Dgraph.Transactions.IQuery  dgraphTransaction)
    {
        _dgraphTransaction = dgraphTransaction;
    }

    public async Task<IOperationResultData> QueryAsync(string query)
    {
        try
        {
            var transaction = _dgraphTransaction;
            var result = await transaction.Query(query);
            
            if (result.IsSuccess)
            {
                return OperationResultData.Success(result.Value.Json);
            }
            else
            {
                return OperationResultData.Failure(result.Errors[0].Message);
            }
        }
        catch (Exception ex)
        {   
            return OperationResultData.Failure(ex.Message, ex);
        }
    }

    public void Dispose()
    {
        // Les transactions Dgraph ne semblent pas implémenter IDisposable
    }
}