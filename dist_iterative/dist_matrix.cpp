#include "dist_objects.h"

// assumes that the matrix is symmetric
// does a 1D decomposition over the rows
Distributed_matrix::Distributed_matrix(
    int matrix_size,
    int nnz,
    int *counts,
    int *displacements,
    int *col_indices_in,
    int *row_ptr_in,
    double *data_in,
    rocsparse_spmv_alg *algos,
    MPI_Comm comm)
{

    MPI_Comm_size(comm, &size);
    MPI_Comm_rank(comm, &rank);

    this->matrix_size = matrix_size;
    this->nnz = nnz;
    this->comm = comm;
    step_count = 0;

    this->counts = new int[size];
    this->displacements = new int[size];
    for(int i = 0; i < size; i++){
        this->counts[i] = counts[i];
        this->displacements[i] = displacements[i];
    }

    rows_this_rank = counts[rank];

    // find neighbours_flag
    neighbours_flag = new bool[size];
    find_neighbours(col_indices_in, row_ptr_in);
    
    neighbours = new int[number_of_neighbours];
    nnz_per_neighbour = new int[number_of_neighbours];
    
    construct_neighbours_list();
    construct_nnz_per_neighbour(col_indices_in, row_ptr_in);

    // order of calls is important
    create_host_memory();
    // split data, indices and row_ptr_in
    split_csr(col_indices_in, row_ptr_in, data_in);

    construct_nnz_cols_per_neighbour();
    construct_nnz_rows_per_neighbour();
    construct_cols_per_neighbour();
    construct_rows_per_neighbour();

    // check_sorted();
    construct_mpi_data_types();
    create_events_streams();
    create_device_memory();

    // populate
    for(int k = 0; k < number_of_neighbours; k++){
        cudaErrchk(hipMemcpy(data_d[k], data_h[k], nnz_per_neighbour[k]*sizeof(double), hipMemcpyHostToDevice));
        cudaErrchk(hipMemcpy(col_indices_d[k], col_indices_h[k], nnz_per_neighbour[k]*sizeof(int), hipMemcpyHostToDevice));
        cudaErrchk(hipMemcpy(row_ptr_d[k], row_ptr_h[k], (rows_this_rank+1)*sizeof(int), hipMemcpyHostToDevice));
    }
    prepare_spmv(algos);

    create_cg_overhead();
}


Distributed_matrix::Distributed_matrix(
    int matrix_size,
    int *counts_in,
    int *displacements_in,
    int number_of_neighbours,
    int *neighbours_in,
    int **col_indices_in_d,
    int **row_ptr_in_d,
    int *nnz_per_neighbour_in,
    rocsparse_spmv_alg *algos,
    MPI_Comm comm)
{

    MPI_Comm_size(comm, &size);
    MPI_Comm_rank(comm, &rank);

    this->matrix_size = matrix_size;
    this->comm = comm;
    this->number_of_neighbours = number_of_neighbours;
    // this->algo = algo;
    step_count = 0;

    nnz = 0;
    rows_this_rank = counts_in[rank];

    counts = new int[size];
    displacements = new int[size];
    
    neighbours_flag = new bool[size];
    neighbours = new int[number_of_neighbours];
    nnz_per_neighbour = new int[number_of_neighbours];

    for(int i = 0; i < size; i++){
        counts[i] = counts_in[i];
        displacements[i] = displacements_in[i];
    }
    for(int k = 0; k < size; k++){
        neighbours_flag[k] = false;
    }
    for(int k = 0; k < number_of_neighbours; k++){
        neighbours_flag[neighbours_in[k]] = true;
    }
    for(int k = 0; k < number_of_neighbours; k++){
        neighbours[k] = neighbours_in[k];
        nnz_per_neighbour[k] = nnz_per_neighbour_in[k];
        nnz += nnz_per_neighbour[k];
    }

    // order of calls is important

    create_host_memory();
    create_device_memory();

    // copy inputs
    for(int k = 0; k < number_of_neighbours; k++){
        cudaErrchk(hipMemcpy(col_indices_d[k], col_indices_in_d[k], nnz_per_neighbour[k]*sizeof(int), hipMemcpyDeviceToDevice));
        cudaErrchk(hipMemcpy(row_ptr_d[k], row_ptr_in_d[k], (rows_this_rank+1)*sizeof(int), hipMemcpyDeviceToDevice));
        cudaErrchk(hipMemcpy(col_indices_h[k], col_indices_in_d[k], nnz_per_neighbour[k]*sizeof(int), hipMemcpyDeviceToHost));
        cudaErrchk(hipMemcpy(row_ptr_h[k], row_ptr_in_d[k], (rows_this_rank+1)*sizeof(int), hipMemcpyDeviceToHost));
    }

    prepare_spmv(algos);
    construct_nnz_cols_per_neighbour();
    construct_nnz_rows_per_neighbour();
    construct_cols_per_neighbour();
    construct_rows_per_neighbour();
    // check_sorted();
    construct_mpi_data_types();
    create_events_streams();

    create_cg_overhead();
}



Distributed_matrix::~Distributed_matrix(){
    delete[] counts;
    delete[] displacements;
    delete[] neighbours_flag;
    delete[] neighbours;
    delete[] nnz_per_neighbour;
    delete[] nnz_cols_per_neighbour;
    for(int k = 0; k < number_of_neighbours; k++){
        delete[] data_h[k];
        delete[] col_indices_h[k];
        delete[] row_ptr_h[k];
    }
    delete[] data_h;
    delete[] col_indices_h;
    delete[] row_ptr_h;
    delete[] nnz_rows_per_neighbour;

    for(int k = 0; k < number_of_neighbours; k++){
        delete[] cols_per_neighbour_h[k];
        delete[] rows_per_neighbour_h[k];
    }
    delete[] cols_per_neighbour_h;
    delete[] rows_per_neighbour_h;

    for(int k = 0; k < number_of_neighbours; k++){
        cudaErrchk(hipFree(cols_per_neighbour_d[k]));
        cudaErrchk(hipFree(rows_per_neighbour_d[k]));
    }
    delete[] cols_per_neighbour_d;
    delete[] rows_per_neighbour_d;

    for(int k = 1; k < number_of_neighbours; k++){
        cudaErrchk(hipHostFree(send_buffer_h[k]));
        cudaErrchk(hipHostFree(recv_buffer_h[k]));
        cudaErrchk(hipFree(send_buffer_d[k]));
        cudaErrchk(hipFree(recv_buffer_d[k]));
    }
    delete[] send_buffer_h;
    delete[] recv_buffer_h;
    delete[] send_buffer_d;
    delete[] recv_buffer_d;

    for(int k = 0; k < number_of_neighbours-1; k++){
        MPI_Type_free(&send_types[k]);
        MPI_Type_free(&recv_types[k]);
    }
    delete[] send_types;
    delete[] recv_types;

    for(int k = 0; k < number_of_neighbours; k++){
        cudaErrchk(hipFree(data_d[k]));
        cudaErrchk(hipFree(col_indices_d[k]));
        cudaErrchk(hipFree(row_ptr_d[k]));
        cudaErrchk(hipFree(buffer_d[k]));
        rocsparse_destroy_spmat_descr(descriptors[k]);
    }
    delete[] buffer_d;
    delete[] data_d;
    delete[] col_indices_d;
    delete[] row_ptr_d;
    delete[] descriptors;
    delete[] buffer_size;

    delete[] send_requests;
    delete[] recv_requests;
    for (int i = 0; i < number_of_neighbours; i++)
    {
        cudaErrchk(hipStreamDestroy(streams_recv[i]));
        cudaErrchk(hipStreamDestroy(streams_send[i]));
        cudaErrchk(hipEventDestroy(events_recv[i]));
        cudaErrchk(hipEventDestroy(events_send[i]));
    }
    delete[] streams_recv;
    delete[] streams_send;
    delete[] events_recv;
    delete[] events_send;
    cudaErrchk(hipEventDestroy(event_default_finished));

    for (int i = 0; i < number_of_neighbours; i++){
        rocsparse_destroy_mat_descr(descr_low[i]);
        rocsparse_destroy_mat_info(infos_low[i]);
    }

    delete[] algos_generic;
    delete[] infos_low;
    delete[] descr_low;

    destroy_cg_overhead();

}

void Distributed_matrix::find_neighbours(
    int *col_indices_in,
    int *row_ptr_in
){

    for(int k = 0; k < size; k++){
        bool tmp = false;
        #pragma omp parallel for reduction(||:tmp)
        for(int i = 0; i < rows_this_rank; i++){
            for(int j = row_ptr_in[i]; j < row_ptr_in[i+1]; j++){
                int col_idx = col_indices_in[j];
                if(col_idx >= displacements[k] && col_idx < displacements[k] + counts[k]){
                    tmp = true;
                }
            }
        }
        neighbours_flag[k] = tmp;
    }
    int tmp_number_of_neighbours = 0;
    for(int k = 0; k < size; k++){
        if(neighbours_flag[k]){
            tmp_number_of_neighbours++;
        }
    }

    number_of_neighbours = tmp_number_of_neighbours;

}

void Distributed_matrix::construct_neighbours_list(
){
    int tmp_number_of_neighbours = 0;
    for(int k = 0; k < size; k++){
        int idx = (rank + k) % size;
        if(neighbours_flag[idx]){
            neighbours[tmp_number_of_neighbours] = idx;
            tmp_number_of_neighbours++;
        }
    }
}

void Distributed_matrix::construct_nnz_per_neighbour(
    int *col_indices_in,
    int *row_ptr_in
)
{
    for(int k = 0; k < number_of_neighbours; k++){
        nnz_per_neighbour[k] = 0;
    }

    for(int k = 0; k < number_of_neighbours; k++){
        int neighbour_idx = neighbours[k];
        int tmp = 0;
        #pragma omp parallel for reduction(+:tmp)
        for(int i = 0; i < rows_this_rank; i++){
            for(int j = row_ptr_in[i]; j < row_ptr_in[i+1]; j++){
                int col_idx = col_indices_in[j];
                if(col_idx >= displacements[neighbour_idx] && col_idx < displacements[neighbour_idx] + counts[neighbour_idx]){
                    tmp++;
                }
            }
        }
        nnz_per_neighbour[k] = tmp;
    }

}



void Distributed_matrix::split_csr(
    int *col_indices_in,
    int *row_ptr_in,
    double *data_in
){
    int *tmp_nnz_per_neighbour = new int[number_of_neighbours];
    for(int k = 0; k < number_of_neighbours; k++){
        tmp_nnz_per_neighbour[k] = 0;
    }
    #pragma omp parallel for
    for(int k = 0; k < number_of_neighbours; k++){
        int tmp = 0;
        for(int i = 0; i < rows_this_rank; i++){
            row_ptr_h[k][i] = tmp;
        

            for(int j = row_ptr_in[i]; j < row_ptr_in[i+1]; j++){
                int neighbour_idx = neighbours[k];
                int col_idx = col_indices_in[j];
                if(col_idx >= displacements[neighbour_idx] && col_idx < displacements[neighbour_idx] + counts[neighbour_idx]){
                    data_h[k][tmp] = data_in[j];
                    col_indices_h[k][tmp] = col_idx - displacements[neighbour_idx];
                    tmp++;
                }
            }
        }
        tmp_nnz_per_neighbour[k] = tmp;
    }

    for(int k = 0; k < number_of_neighbours; k++){
        row_ptr_h[k][rows_this_rank] = tmp_nnz_per_neighbour[k];
    }


    for(int k = 0; k < number_of_neighbours; k++){
        if(tmp_nnz_per_neighbour[k] != nnz_per_neighbour[k]){
            std::cout << "Error in split_csr" << std::endl;
        }
    }

    delete[] tmp_nnz_per_neighbour;

}

void Distributed_matrix::construct_nnz_cols_per_neighbour(
)
{

    nnz_cols_per_neighbour = new int[number_of_neighbours];

    #pragma omp parallel for
    for(int k = 0; k < number_of_neighbours; k++){
        nnz_cols_per_neighbour[k] = 0;
        int tmp = 0;
        int neighbour_idx = neighbours[k];
        bool *cols_per_neighbour_flags = new bool[counts[neighbour_idx]];
        for(int i = 0; i < counts[neighbour_idx]; i++){
            cols_per_neighbour_flags[i] = false;
        }
        for(int i = 0; i < rows_this_rank; i++){
            for(int j = row_ptr_h[k][i]; j < row_ptr_h[k][i+1]; j++){
                int col_idx = col_indices_h[k][j];
                cols_per_neighbour_flags[col_idx] = true;
            }
        }
        for(int i = 0; i < counts[neighbour_idx]; i++){
            if(cols_per_neighbour_flags[i]){
                tmp++;
            }
        }
        nnz_cols_per_neighbour[k] = tmp;
        delete[] cols_per_neighbour_flags;
    }

    recv_buffer_h = new double*[number_of_neighbours];
    recv_buffer_d = new double*[number_of_neighbours];

    for(int k = 1; k < number_of_neighbours; k++){
        cudaErrchk(hipHostMalloc(&recv_buffer_h[k], nnz_cols_per_neighbour[k]*sizeof(double)));
        cudaErrchk(hipMalloc(&recv_buffer_d[k], nnz_cols_per_neighbour[k]*sizeof(double)));
    }

}

void Distributed_matrix::construct_nnz_rows_per_neighbour()
{

    nnz_rows_per_neighbour = new int[number_of_neighbours];

    for(int i = 0; i < number_of_neighbours; i++){
        nnz_rows_per_neighbour[i] = 0;
    }
    for(int k = 0; k < number_of_neighbours; k++){
        int tmp = 0;
        #pragma omp parallel for reduction(+:tmp)
        for(int i = 0; i < rows_this_rank; i++){
            if(row_ptr_h[k][i+1] - row_ptr_h[k][i] > 0){
                tmp++;
            }
        }
        nnz_rows_per_neighbour[k] = tmp;
    }

    send_buffer_h = new double*[number_of_neighbours];
    send_buffer_d = new double*[number_of_neighbours];

    for(int k = 1; k < number_of_neighbours; k++){
        cudaErrchk(hipHostMalloc(&send_buffer_h[k], nnz_rows_per_neighbour[k]*sizeof(double)));
        cudaErrchk(hipMalloc(&send_buffer_d[k], nnz_rows_per_neighbour[k]*sizeof(double)));
    }

}

void Distributed_matrix::construct_rows_per_neighbour()
{

    rows_per_neighbour_h = new int*[number_of_neighbours];    
    for(int k = 0; k < number_of_neighbours; k++){
        rows_per_neighbour_h[k] = new int[nnz_rows_per_neighbour[k]];
    }

    int *tmp_nnz_rows_per_neighbour = new int[number_of_neighbours];
    for(int i = 0; i < number_of_neighbours; i++){
        tmp_nnz_rows_per_neighbour[i] = 0;
    }
    #pragma omp parallel for
    for(int k = 0; k < number_of_neighbours; k++){
        for(int i = 0; i < rows_this_rank; i++){
            if(row_ptr_h[k][i+1] - row_ptr_h[k][i] > 0){
                rows_per_neighbour_h[k][tmp_nnz_rows_per_neighbour[k]] = i;
                tmp_nnz_rows_per_neighbour[k]++;
            }
        }
    }
    delete[] tmp_nnz_rows_per_neighbour;

    rows_per_neighbour_d = new int*[number_of_neighbours];

    for(int k = 0; k < number_of_neighbours; k++){
        cudaErrchk(hipMalloc(&rows_per_neighbour_d[k], nnz_rows_per_neighbour[k]*sizeof(int)));
        cudaErrchk(hipMemcpy(rows_per_neighbour_d[k], rows_per_neighbour_h[k], nnz_rows_per_neighbour[k]*sizeof(int), hipMemcpyHostToDevice));
    }
}   


void Distributed_matrix::construct_cols_per_neighbour()
{
    cols_per_neighbour_h = new int*[number_of_neighbours];
    for(int k = 0; k < number_of_neighbours; k++){
        cols_per_neighbour_h[k] = new int[nnz_cols_per_neighbour[k]];
    }
    #pragma omp parallel for
    for(int k = 0; k < number_of_neighbours; k++){
        int neighbour_idx = neighbours[k];
        bool *cols_per_neighbour_flags = new bool[counts[neighbour_idx]];
        for(int i = 0; i < counts[neighbour_idx]; i++){
            cols_per_neighbour_flags[i] = false;
        }
        for(int i = 0; i < rows_this_rank; i++){
            for(int j = row_ptr_h[k][i]; j < row_ptr_h[k][i+1]; j++){
                int col_idx = col_indices_h[k][j];
                cols_per_neighbour_flags[col_idx] = true;
            }
        }
        int tmp_nnz_cols = 0;
        for(int i = 0; i < counts[neighbour_idx]; i++){
            if(cols_per_neighbour_flags[i]){
                cols_per_neighbour_h[k][tmp_nnz_cols] = i;
                tmp_nnz_cols++;
            }
        }
        delete[] cols_per_neighbour_flags;
    }

    cols_per_neighbour_d = new int*[number_of_neighbours];

    for(int k = 0; k < number_of_neighbours; k++){
        cudaErrchk(hipMalloc(&cols_per_neighbour_d[k], nnz_cols_per_neighbour[k]*sizeof(int)));
        cudaErrchk(hipMemcpy(cols_per_neighbour_d[k], cols_per_neighbour_h[k], nnz_cols_per_neighbour[k]*sizeof(int), hipMemcpyHostToDevice));
    }

}  

void Distributed_matrix::check_sorted(){
    bool sorted = true;
    for(int d = 0; d < size; d++){
        if(rank == d){
            for(int k = 0; k < number_of_neighbours; k++){
                for(int i = 0; i < nnz_cols_per_neighbour[k]-1; i++){
                    if(cols_per_neighbour_h[k][i] > cols_per_neighbour_h[k][i+1]){
                        std::cout << rank << " " << i << " " << cols_per_neighbour_h[k][i] << " " << cols_per_neighbour_h[k][i+1] << std::endl;
                        std::cout << rank << " " << "Error in sorted indices col" << std::endl;
                        sorted = false;
                        break;
                    }
                }
                for(int i = 0; i < nnz_rows_per_neighbour[k]-1; i++){
                    if(rows_per_neighbour_h[k][i] > rows_per_neighbour_h[k][i+1]){
                        std::cout << rank << " " << i << " " << rows_per_neighbour_h[k][i] << " " << rows_per_neighbour_h[k][i+1] << std::endl;
                        std::cout << rank << " " << "Error in sorted indices rows" << std::endl;
                        sorted = false;
                        break;
                    }
                }
            }
        }
        sleep(1);
        MPI_Barrier(comm);
    }
    if(!sorted){
        std::cout << rank << " " << "Indices are not sorted" << std::endl;
    }
}

void Distributed_matrix::construct_mpi_data_types(){
    send_types = new MPI_Datatype[number_of_neighbours];
    recv_types = new MPI_Datatype[number_of_neighbours];
    for(int k = 0; k < number_of_neighbours-1; k++){

        int *lengths = new int[nnz_rows_per_neighbour[k+1]];
        for(int i = 0; i < nnz_rows_per_neighbour[k+1]; i++){
            lengths[i] = 1;
        }
        MPI_Type_indexed(nnz_rows_per_neighbour[k+1], lengths,
                        rows_per_neighbour_h[k+1], MPI_DOUBLE, &send_types[k]);
        MPI_Type_commit(&send_types[k]);
        delete[] lengths;
    }
    for(int k = 0; k < number_of_neighbours-1; k++){
        int *lengths = new int[nnz_cols_per_neighbour[k+1]];
        for(int i = 0; i < nnz_cols_per_neighbour[k+1]; i++){
            lengths[i] = 1;
        }
        MPI_Type_indexed(nnz_cols_per_neighbour[k+1],lengths,
                        cols_per_neighbour_h[k+1], MPI_DOUBLE, &recv_types[k]);
        MPI_Type_commit(&recv_types[k]);
        delete[] lengths;
    }
}

void Distributed_matrix::create_events_streams(){
    send_requests = new MPI_Request[number_of_neighbours];
    recv_requests = new MPI_Request[number_of_neighbours];
    streams_recv = new hipStream_t[number_of_neighbours];
    streams_send = new hipStream_t[number_of_neighbours];
    events_recv = new hipEvent_t[number_of_neighbours];
    events_send = new hipEvent_t[number_of_neighbours];
    for (int i = 0; i < number_of_neighbours; i++)
    {
        cudaErrchk(hipStreamCreate(&streams_recv[i]));
        cudaErrchk(hipStreamCreate(&streams_send[i]));
        cudaErrchk(hipEventCreateWithFlags(&events_recv[i], hipEventDisableTiming));
        cudaErrchk(hipEventCreateWithFlags(&events_send[i], hipEventDisableTiming));
    }
    cudaErrchk(hipEventCreateWithFlags(&event_default_finished, hipEventDisableTiming));
}

void Distributed_matrix::create_host_memory(){
    data_h = new double*[number_of_neighbours];
    col_indices_h = new int*[number_of_neighbours];
    row_ptr_h = new int*[number_of_neighbours];    
    for(int k = 0; k < number_of_neighbours; k++){
        data_h[k] = new double[nnz_per_neighbour[k]];
        col_indices_h[k] = new int[nnz_per_neighbour[k]];
        row_ptr_h[k] = new int[rows_this_rank+1];        
    }
}

void Distributed_matrix::create_device_memory(){
    data_d = new double*[number_of_neighbours];
    col_indices_d = new int*[number_of_neighbours];
    row_ptr_d = new int*[number_of_neighbours];
    
    for(int k = 0; k < number_of_neighbours; k++){
        int neighbour_idx = neighbours[k];
        cudaErrchk(hipMalloc(&data_d[k], nnz_per_neighbour[k]*sizeof(double)));
        cudaErrchk(hipMalloc(&col_indices_d[k], nnz_per_neighbour[k]*sizeof(int)));
        cudaErrchk(hipMalloc(&row_ptr_d[k], (rows_this_rank+1)*sizeof(int)));
    }
}

void Distributed_matrix::prepare_spmv(
    rocsparse_spmv_alg *algos
){
    buffer_size = new size_t[number_of_neighbours];
    buffer_d = new double*[number_of_neighbours];
    descriptors = new rocsparse_spmat_descr[number_of_neighbours];

    rocsparse_handle rocsparseHandle;
    rocsparse_create_handle(&rocsparseHandle);

    algos_generic = new rocsparse_spmv_alg[number_of_neighbours];
    for(int i = 0; i < number_of_neighbours; i++){
        algos_generic[i] = algos[i];
    }
    // algos_generic[0] = rocsparse_spmv_alg_csr_adaptive;
    // for(int k = 1; k < number_of_neighbours; k++){
    //     algos_generic[k] = rocsparse_spmv_alg_csr_stream;
    // }

    infos_low = new rocsparse_mat_info[number_of_neighbours];
    descr_low = new rocsparse_mat_descr[number_of_neighbours];



    for(int k = 0; k < number_of_neighbours; k++){
        int neighbour_idx = neighbours[k];

        double *vec_in_d;
        double *vec_out_d;
        rocsparse_dnvec_descr vec_in;
        rocsparse_dnvec_descr vec_out;

        cudaErrchk(hipMalloc(&vec_in_d, counts[neighbour_idx]*sizeof(double)));
        cudaErrchk(hipMalloc(&vec_out_d, rows_this_rank*sizeof(double)));
        rocsparse_create_dnvec_descr(&vec_in,
            counts[neighbour_idx], vec_in_d, rocsparse_datatype_f64_r);
        rocsparse_create_dnvec_descr(&vec_out,
            rows_this_rank, vec_out_d, rocsparse_datatype_f64_r);


        rocsparse_create_csr_descr(
            &descriptors[k],
            rows_this_rank,
            counts[neighbour_idx],
            nnz_per_neighbour[k],
            row_ptr_d[k],
            col_indices_d[k],
            data_d[k],
            rocsparse_indextype_i32,
            rocsparse_indextype_i32,
            rocsparse_index_base_zero,
            rocsparse_datatype_f64_r);

        double alpha = 1.0;
        double beta = 0.0;

        rocsparseErrchk(rocsparse_spmv(
            rocsparseHandle,
            rocsparse_operation_none,
            &alpha,
            descriptors[k],
            vec_in,
            &beta,
            vec_out,
            rocsparse_datatype_f64_r,
            algos_generic[k],
            &buffer_size[k],
            nullptr));
        cudaErrchk(hipMalloc(&buffer_d[k], buffer_size[k]));

        rocsparse_destroy_dnvec_descr(vec_in);
        rocsparse_destroy_dnvec_descr(vec_out);
        cudaErrchk(hipFree(vec_in_d));
        cudaErrchk(hipFree(vec_out_d));

        rocsparse_create_mat_descr(&descr_low[k]);
        rocsparse_create_mat_info(&infos_low[k]);

        rocsparse_dcsrmv_analysis(
            rocsparseHandle,
            rocsparse_operation_none,
            rows_this_rank,
            counts[neighbour_idx],
            nnz_per_neighbour[k],
            descr_low[k],
            data_d[k],
            row_ptr_d[k],
            col_indices_d[k],
            infos_low[k]);

    }

    rocsparse_destroy_handle(rocsparseHandle);
}

void Distributed_matrix::create_cg_overhead(
){
    // initialize cuda
    cublasErrchk(hipblasCreate(&default_cublasHandle));
    cusparseErrchk(hipsparseCreate(&default_cusparseHandle));    
    rocsparse_create_handle(&default_rocsparseHandle);
    cudaErrchk(hipStreamCreate(&default_stream));
    cusparseErrchk(hipsparseSetStream(default_cusparseHandle, default_stream));
    cublasErrchk(hipblasSetStream(default_cublasHandle, default_stream));
    rocsparse_set_stream(default_rocsparseHandle, default_stream);
    cudaErrchk(hipMalloc((void **)&Ap_local_d, rows_this_rank * sizeof(double)));
    rocsparse_create_dnvec_descr(&vecAp_local,
                                rows_this_rank,
                                Ap_local_d,
                                rocsparse_datatype_f64_r);
    cudaErrchk(hipMalloc((void **)&z_local_d, rows_this_rank * sizeof(double)));    
}

void Distributed_matrix::destroy_cg_overhead(
){
    rocsparse_destroy_handle(default_rocsparseHandle);
    cusparseErrchk(hipsparseDestroy(default_cusparseHandle));
    cublasErrchk(hipblasDestroy(default_cublasHandle));
    cudaErrchk(hipStreamDestroy(default_stream));
    rocsparse_destroy_dnvec_descr(vecAp_local);
    cudaErrchk(hipFree(Ap_local_d));    
    cudaErrchk(hipFree(z_local_d));



}