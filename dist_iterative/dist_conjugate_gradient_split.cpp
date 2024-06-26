#include "dist_conjugate_gradient.h"
#include "dist_spmv.h"
namespace iterative_solver{


template <void (*distributed_spmv_split)
    (Distributed_subblock &,
    Distributed_matrix &,    
    double *,
    double *,
    Distributed_vector &,
    double *,
    rocsparse_dnvec_descr &,
    double *,
    hipStream_t &,
    rocblas_handle &,
    rocsparse_handle&)>
void conjugate_gradient_jacobi_split(
    Distributed_subblock &A_subblock,
    Distributed_matrix &A_distributed,
    Distributed_vector &p_distributed,
    double *r_local_d,
    double *x_local_d,
    double *diag_inv_local_d,
    double relative_tolerance,
    int max_iterations,
    MPI_Comm comm)
{

    // initialize cuda
    hipStream_t default_stream = NULL;
    hipblasHandle_t default_cublasHandle = 0;
    cublasErrchk(hipblasCreate(&default_cublasHandle));
    
    hipsparseHandle_t default_cusparseHandle = 0;
    cusparseErrchk(hipsparseCreate(&default_cusparseHandle));    

    rocsparse_handle default_rocsparseHandle;
    rocsparse_create_handle(&default_rocsparseHandle);

    rocblas_handle default_rocblasHandle;
    rocblas_create_handle(&default_rocblasHandle);

    cudaErrchk(hipStreamCreate(&default_stream));
    cusparseErrchk(hipsparseSetStream(default_cusparseHandle, default_stream));
    cublasErrchk(hipblasSetStream(default_cublasHandle, default_stream));
    rocsparse_set_stream(default_rocsparseHandle, default_stream);
    rocblas_set_stream(default_rocblasHandle, default_stream);

    double a, b, na;
    double alpha, alpham1, r0;
    // double *r_norm2_h;
    // double *dot_h;    
    // cudaErrchk(hipHostMalloc((void**)&r_norm2_h, sizeof(double)));
    // cudaErrchk(hipHostMalloc((void**)&dot_h, sizeof(double)));
    double    r_norm2_h[1];
    double    dot_h[1];

    alpha = 1.0;
    alpham1 = -1.0;
    r0 = 0.0;

    //copy data to device
    // starting guess for p
    cudaErrchk(hipMemcpy(p_distributed.vec_d[0], x_local_d,
        p_distributed.counts[A_distributed.rank] * sizeof(double), hipMemcpyDeviceToDevice));

    double *Ap_local_d = NULL;
    cudaErrchk(hipMalloc((void **)&Ap_local_d, A_distributed.rows_this_rank * sizeof(double)));
    cudaErrchk(hipMemset(Ap_local_d, 0, A_distributed.rows_this_rank * sizeof(double)));
    rocsparse_dnvec_descr vecAp_local = NULL;
    rocsparse_create_dnvec_descr(&vecAp_local,
                                A_distributed.rows_this_rank,
                                Ap_local_d,
                                rocsparse_datatype_f64_r);
    
    double *z_local_d = NULL;
    cudaErrchk(hipMalloc((void **)&z_local_d, A_distributed.rows_this_rank * sizeof(double)));

    // dense subblock product y=Ax
    double *p_subblock_d = NULL;
    double *Ap_subblock_d = NULL;
    cudaErrchk(hipMalloc((void **)&p_subblock_d,
        A_subblock.subblock_size * sizeof(double)));
    cudaErrchk(hipMalloc((void **)&Ap_subblock_d,
        A_subblock.count_subblock_h[A_distributed.rank] * sizeof(double)));
    double *p_subblock_h;
    cudaErrchk(hipHostMalloc((void**)&p_subblock_h, A_subblock.subblock_size * sizeof(double)));

    //begin CG

    // norm of rhs for convergence check
    double norm2_rhs = 0;
    cublasErrchk(hipblasDdot(default_cublasHandle, A_distributed.rows_this_rank, r_local_d, 1, r_local_d, 1, &norm2_rhs));
    MPI_Allreduce(MPI_IN_PLACE, &norm2_rhs, 1, MPI_DOUBLE, MPI_SUM, comm);

    // A*x0
    distributed_spmv_split(
        A_subblock,
        A_distributed,
        p_subblock_d,
        p_subblock_h,
        p_distributed,
        Ap_subblock_d,
        vecAp_local,
        Ap_local_d,
        default_stream,
        default_rocblasHandle,
        default_rocsparseHandle
    );


    // cal residual r0 = b - A*x0
    // r_norm2_h = r0*r0
    cublasErrchk(hipblasDaxpy(default_cublasHandle, A_distributed.rows_this_rank, &alpham1, Ap_local_d, 1, r_local_d, 1));
    
    // Mz = r
    elementwise_vector_vector(
        r_local_d,
        diag_inv_local_d,
        z_local_d,
        A_distributed.rows_this_rank,
        default_stream
    ); 
    
    cublasErrchk(hipblasDdot(default_cublasHandle, A_distributed.rows_this_rank, r_local_d, 1, z_local_d, 1, r_norm2_h));
    MPI_Allreduce(MPI_IN_PLACE, r_norm2_h, 1, MPI_DOUBLE, MPI_SUM, comm);


    int k = 1;
    while (r_norm2_h[0]/norm2_rhs > relative_tolerance * relative_tolerance && k <= max_iterations) {
        if(k > 1){
            // pk+1 = rk+1 + b*pk
            b = r_norm2_h[0] / r0;
            cublasErrchk(hipblasDscal(default_cublasHandle, A_distributed.rows_this_rank, &b, p_distributed.vec_d[0], 1));
            cublasErrchk(hipblasDaxpy(default_cublasHandle, A_distributed.rows_this_rank, &alpha, z_local_d, 1, p_distributed.vec_d[0], 1)); 
        }
        else {
            // p0 = r0
            cublasErrchk(hipblasDcopy(default_cublasHandle, A_distributed.rows_this_rank, z_local_d, 1, p_distributed.vec_d[0], 1));
        }


        // ak = rk^T * rk / pk^T * A * pk
        // has to be done for k=0 if x0 != 0
        distributed_spmv_split(
            A_subblock,
            A_distributed,
            p_subblock_d,
            p_subblock_h,
            p_distributed,
            Ap_subblock_d,
            vecAp_local,
            Ap_local_d,
            default_stream,
            default_rocblasHandle,
            default_rocsparseHandle
        );

        cublasErrchk(hipblasDdot(default_cublasHandle, A_distributed.rows_this_rank, p_distributed.vec_d[0], 1, Ap_local_d, 1, dot_h));
        MPI_Allreduce(MPI_IN_PLACE, dot_h, 1, MPI_DOUBLE, MPI_SUM, comm);

        a = r_norm2_h[0] / dot_h[0];

        // xk+1 = xk + ak * pk
        cublasErrchk(hipblasDaxpy(default_cublasHandle, A_distributed.rows_this_rank, &a, p_distributed.vec_d[0], 1, x_local_d, 1));

        // rk+1 = rk - ak * A * pk
        na = -a;
        cublasErrchk(hipblasDaxpy(default_cublasHandle, A_distributed.rows_this_rank, &na, Ap_local_d, 1, r_local_d, 1));
        r0 = r_norm2_h[0];

        // Mz = r
        elementwise_vector_vector(
            r_local_d,
            diag_inv_local_d,
            z_local_d,
            A_distributed.rows_this_rank,
            default_stream
        ); 
        

        // r_norm2_h = r0*r0
        cublasErrchk(hipblasDdot(default_cublasHandle, A_distributed.rows_this_rank, r_local_d, 1, z_local_d, 1, r_norm2_h));
        MPI_Allreduce(MPI_IN_PLACE, r_norm2_h, 1, MPI_DOUBLE, MPI_SUM, comm);
        k++;
    }

    //end CG
    cudaErrchk(hipDeviceSynchronize());
    if(A_distributed.rank == 0){
        std::cout << "iteration T = " << k << ", relative residual = " << sqrt(r_norm2_h[0]/norm2_rhs) << std::endl;
    }

    rocsparse_destroy_handle(default_rocsparseHandle);
    cusparseErrchk(hipsparseDestroy(default_cusparseHandle));
    cublasErrchk(hipblasDestroy(default_cublasHandle));
    rocblasErrchk(rocblas_destroy_handle(default_rocblasHandle));
    cudaErrchk(hipStreamDestroy(default_stream));
    rocsparse_destroy_dnvec_descr(vecAp_local);
    cudaErrchk(hipFree(Ap_local_d));
    cudaErrchk(hipFree(z_local_d));

    // cudaErrchk(hipHostFree(r_norm2_h));
    // cudaErrchk(hipHostFree(dot_h));
    cudaErrchk(hipFree(p_subblock_d));
    cudaErrchk(hipFree(Ap_subblock_d));
    cudaErrchk(hipHostFree(p_subblock_h));

}
template 
void conjugate_gradient_jacobi_split<dspmv_split::spmm_split1>(
    Distributed_subblock &A_subblock,
    Distributed_matrix &A_distributed,
    Distributed_vector &p_distributed,
    double *r_local_d,
    double *x_local_d,
    double *diag_inv_local_d,
    double relative_tolerance,
    int max_iterations,
    MPI_Comm comm);
template 
void conjugate_gradient_jacobi_split<dspmv_split::spmm_split2>(
    Distributed_subblock &A_subblock,
    Distributed_matrix &A_distributed,
    Distributed_vector &p_distributed,
    double *r_local_d,
    double *x_local_d,
    double *diag_inv_local_d,
    double relative_tolerance,
    int max_iterations,
    MPI_Comm comm);
} // namespace iterative_solver